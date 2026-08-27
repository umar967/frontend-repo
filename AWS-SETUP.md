# AWS setup

This project deploys the frontend, backend, and MySQL as one ECS Fargate task. The frontend is the only public entry point; the backend and MySQL communicate over the task-local network (`127.0.0.1`). This is suitable for a lab or demonstration. For production, move MySQL to Amazon RDS and put the frontend behind an Application Load Balancer.

## 1. Prerequisites

Install and configure the AWS CLI, then select the target account and region:

```bash
aws configure
aws sts get-caller-identity
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

On PowerShell, use `$env:AWS_REGION = "us-east-1"` and `$env:AWS_ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)` instead.

The commands below use the default VPC. For a real deployment, use a dedicated VPC with private subnets for the task and a public load balancer subnet.

## 2. Create ECR repositories

Run once:

```bash
aws ecr create-repository --repository-name my-backend-repo --region $AWS_REGION
aws ecr create-repository --repository-name my-frontend-repo --region $AWS_REGION
```

Build and push the initial images from each repository. Run the backend commands in `backend/` and the frontend commands in `frontend/`:

```bash
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

docker build -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/my-backend-repo:latest ./backend
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/my-backend-repo:latest

docker build -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/my-frontend-repo:latest ./frontend
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/my-frontend-repo:latest
```

## 3. Create IAM execution role

Create an ECS task execution role trusted by ECS tasks:

```bash
aws iam create-role \
  --role-name ecsTaskExecutionRole \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

The checked-in task definition currently contains an account-specific role ARN. Before registering it, replace the account ID with your own account ID and use the ECR image URIs created above. Also replace the example database password. Do not commit real passwords.

## 4. Create ECS resources

Create the cluster and log group:

```bash
aws logs create-log-group --log-group-name /ecs/local-db-task --region $AWS_REGION
aws ecs create-cluster --cluster-name my-fargate-cluster --region $AWS_REGION
```

Register `task-definition.json` from the workspace root after making the substitutions described above:

```bash
aws ecs register-task-definition \
  --cli-input-json file://task-definition.json \
  --region $AWS_REGION
```

The task definition expects these container names and ports:

| Container | Port | Role |
|---|---:|---|
| `mysql-db` | 3306 | Database, task-local only |
| `backend-app` | 5001 | Express API, task-local only |
| `frontend-app` | 80 | Public web application |

## 5. Networking and service

Find subnets in the default VPC and create a security group that allows HTTP only:

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET_1=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[0].SubnetId' --output text)
SUBNET_2=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[1].SubnetId' --output text)
SG_ID=$(aws ec2 create-security-group --group-name ecs-web-sg --description "HTTP for ECS frontend" --vpc-id $VPC_ID --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
```

Create the service with a public task IP for the lab:

```bash
aws ecs create-service \
  --cluster my-fargate-cluster \
  --service-name frontend-service \
  --task-definition local-db-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --region $AWS_REGION
```

Get the public IP and open it in a browser:

```bash
TASK_ARN=$(aws ecs list-tasks --cluster my-fargate-cluster --service-name frontend-service --query 'taskArns[0]' --output text)
ENI_ID=$(aws ecs describe-tasks --cluster my-fargate-cluster --tasks $TASK_ARN --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query 'NetworkInterfaces[0].Association.PublicIp' --output text
```

## 6. Configure GitHub Actions

Both repositories deploy on a push to `main` and support manual runs from the Actions tab. Add these repository secrets in **Settings > Secrets and variables > Actions** for both repositories:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

Use a dedicated IAM user with only the ECR push, ECS task-definition registration, `iam:PassRole`, and ECS deployment permissions required by the workflows. OIDC-based GitHub Actions authentication is preferred for production because it avoids long-lived access keys.

The workflows assume these AWS names:

| Setting | Value |
|---|---|
| Region | `us-east-1` |
| ECR backend repository | `my-backend-repo` |
| ECR frontend repository | `my-frontend-repo` |
| ECS cluster | `my-fargate-cluster` |
| ECS service | `frontend-service` |
| ECS task definition family | `local-db-task` |

Push to `main` in either repository. The workflow builds that repository's image, pushes an immutable commit tag to ECR, updates the matching container in `local-db-task`, and waits for ECS service stability.

## Troubleshooting

- `ResourceNotFoundException`: verify the region, cluster, service, and task-definition family names.
- `CannotPullContainerError`: verify the task execution role and that both ECR images exist.
- Frontend loads but API calls fail: confirm `backend-app` is healthy and that the frontend container uses `BACKEND_HOST=127.0.0.1` and `BACKEND_PORT=5001`.
- Database resets after a task replacement: expected with the current task-local MySQL design; use RDS for persistent data.
