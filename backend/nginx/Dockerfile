FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 80

# nginx runs as root by default — fine for this proxy-only image
CMD ["nginx", "-g", "daemon off;"]
