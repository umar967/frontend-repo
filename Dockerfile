FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
COPY default.conf.template /etc/nginx/templates/default.conf.template
ENV BACKEND_HOST=127.0.0.1
ENV BACKEND_PORT=5001
EXPOSE 80
