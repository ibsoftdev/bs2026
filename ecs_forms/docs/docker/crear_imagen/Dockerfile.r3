# Imagen r3 = imagen r2 + dependencias de los ejecutables cliente de Reports (rwclient, rwrun, ...).
# - rwclient requiere libnsl.so.2: en Oracle Linux 9 el paquete libnsl2 (2.0.0) solo trae libnsl.so.3,
#   por lo que se crea el enlace de compatibilidad libnsl.so.2 -> libnsl.so.3.
# - Los binarios rw* de $ORACLE_HOME/bin deben tener permiso de ejecución para el usuario oracle.
#
# Build (desde este directorio):
#   docker build -f Dockerfile.r3 --build-arg BASE_IMAGE=image_forms_14.1.2:r2 \
#     --build-arg RUN_USER=$(docker inspect -f '{{.Config.User}}' image_forms_14.1.2:r2) \
#     -t image_forms_14.1.2:r3 .
#
# RUN_USER conserva el usuario de r2 (vacío = root) para no cambiar el comportamiento en ECS.

ARG BASE_IMAGE=image_forms_14.1.2:r2
FROM ${BASE_IMAGE}
ARG RUN_USER=oracle

USER root
RUN dnf install -y libnsl2 && \
    dnf clean all && \
    ln -sf /usr/lib64/libnsl.so.3 /usr/lib64/libnsl.so.2 && \
    ldconfig && \
    chmod a+x /u01/oracle/bin/rw* && \
    missing=$(for f in /u01/oracle/bin/rwclient /u01/oracle/bin/rwrun /u01/oracle/bin/rwserver \
                       /u01/oracle/bin/rwbuilder /u01/oracle/bin/rwconverter; do \
                [ -f "$f" ] && LD_LIBRARY_PATH=/u01/oracle/lib ldd "$f" | grep 'not found'; \
              done | sort -u) ; \
    if [ -n "$missing" ]; then echo "Faltan librerías:"; echo "$missing"; exit 1; fi && \
    echo "OK: binarios rw* sin dependencias faltantes"

USER ${RUN_USER:-root}
