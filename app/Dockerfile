FROM busybox:1.36
LABEL org.opencontainers.image.source="https://github.com/zkovac-devops/ecr-oci-poc" \
      org.opencontainers.image.description="ECR OCI PoC test image"
COPY index.html /www/index.html
USER 65534
EXPOSE 8080
CMD ["httpd", "-f", "-v", "-p", "8080", "-h", "/www"]
