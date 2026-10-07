# Imagen r2 = imagen r1 (la que está en ECR) + librerías X11/Motif del motor de Reports.
# librw.so / librwu.so requieren libXm.so.4, libX11, libXext, libXt y libXp.
#
# Build (desde este directorio):
#   docker build -f Dockerfile.r2 --build-arg BASE_IMAGE=image_forms_14.1.2:r1 \
#     --build-arg RUN_USER=$(docker inspect -f '{{.Config.User}}' image_forms_14.1.2:r1) \
#     -t image_forms_14.1.2:r2 .
#
# RUN_USER conserva el usuario de r1 (vacío = root) para no cambiar el comportamiento en ECS.

ARG BASE_IMAGE=image_forms_14.1.2:r1
FROM ${BASE_IMAGE}
ARG RUN_USER=oracle

USER root
RUN dnf install -y motif libX11 libXext libXt libXp \
    || (dnf install -y oracle-epel-release-el9 && \
        dnf config-manager --enable ol9_developer_EPEL && \
        dnf install -y motif libX11 libXext libXt libXp) && \
    dnf clean all && \
    missing=$(for f in /u01/oracle/lib/librw*.so; do ldd "$f" | grep 'not found'; done | sort -u) && \
    if [ -n "$missing" ]; then echo "Faltan librerías:"; echo "$missing"; exit 1; fi && \
    echo "OK: librw*.so sin dependencias faltantes"

USER ${RUN_USER:-root}
