# ====================================================================
# STAGE 1: BUILDER - Handles installation of WLS, Forms, and JDK
# ====================================================================
FROM oraclelinux:9 as builder

# --- Environment Variables ---
ENV JAVA_HOME=/u01/jdk \
    ORACLE_HOME=/u01/oracle \
    DOMAIN_HOME=/u01/oracle/user_projects/domains/base_domain \
    INFRA_INSTALLER=fmw_14.1.2.0.0_infrastructure.jar \
    FR_INSTALLER=fmw_14.1.2.0.0_fr_linux64.bin \
    JAVA_INSTALLER=jdk-17_linux-x64_bin.tar.gz

# --- Setup Prerequisites (Root Operations) ---
USER root

# Install required system packages and dependencies
# - libaio / libnsl: runtime deps for Forms / Oracle client tools
# - gcc / make / binutils: required to generate Forms shared libraries (.so) with genshlib
# - nano / net-tools: operational utilities used during image and container administration
RUN dnf install -y unzip tar wget openssl glibc libaio libnsl gcc make binutils nano net-tools && \
    dnf clean all

# Create the user/group, installation directories, and Inventory directory
RUN groupadd -g 1000 oracle && useradd -u 1000 -g oracle -d /u01/oracle -s /bin/bash oracle && \
    mkdir -p ${JAVA_HOME} && \
    mkdir -p ${ORACLE_HOME} && \
    mkdir -p /u01/app/oraInventory && \
    chown -R oracle:oracle /u01 && \
    chown -R oracle:oracle /u01/app/oraInventory

# --- Copy Installers and Create Response Files ---
COPY ./${JAVA_INSTALLER} /tmp/
COPY ./${INFRA_INSTALLER} /tmp/
COPY ./${FR_INSTALLER} /tmp/

# Create silent response file for Infrastructure (infra.rsp)
RUN echo "[ENGINE]" > /tmp/infra.rsp && \
    echo "Response File Version=1.0.0.0.0" >> /tmp/infra.rsp && \
    echo "[GENERIC]" >> /tmp/infra.rsp && \
    echo "ORACLE_HOME=${ORACLE_HOME}" >> /tmp/infra.rsp && \
    echo "INSTALL_TYPE=Fusion Middleware Infrastructure" >> /tmp/infra.rsp && \
    echo "DECLINE_SECURITY_UPDATES=true" >> /tmp/infra.rsp && \
    echo "SECURITY_UPDATES_VIA_MYORACLESUPPORT=false" >> /tmp/infra.rsp && \
    echo "UNIX_GROUP_NAME=oracle" >> /tmp/infra.rsp

# Create silent response file for Forms and Reports (fr.rsp)
# Using the confirmed install type and required Oracle Inventory location file (/tmp/oraInst.loc)
RUN echo "[ENGINE]" > /tmp/fr.rsp && \
    echo "Response File Version=1.0.0.0.0" >> /tmp/fr.rsp && \
    echo "[GENERIC]" >> /tmp/fr.rsp && \
    echo "ORACLE_HOME=${ORACLE_HOME}" >> /tmp/fr.rsp && \
    echo "INSTALL_TYPE=Forms and Reports Deployment" >> /tmp/fr.rsp && \
    echo "DECLINE_SECURITY_UPDATES=true" >> /tmp/fr.rsp && \
    echo "SECURITY_UPDATES_VIA_MYORACLESUPPORT=false" >> /tmp/fr.rsp && \
    echo "UNIX_GROUP_NAME=oracle" >> /tmp/fr.rsp && \
    echo "inventory_loc=/u01/app/oraInventory" > /tmp/oraInst.loc && \
    echo "inst_group=oracle" >> /tmp/oraInst.loc

# Ensure installer files are owned by oracle:
RUN chown -R oracle:oracle /tmp/*.tar.gz && \
    chown -R oracle:oracle /tmp/*.jar && \
    chown -R oracle:oracle /tmp/*.bin && \
    chown -R oracle:oracle /tmp/*.rsp && \
    chown -R oracle:oracle /tmp/oraInst.loc
    

# --- Installation Steps (Run as 'oracle' user) ---
USER oracle

# 1. Install JDK
RUN tar -xzf /tmp/${JAVA_INSTALLER} -C ${JAVA_HOME} --strip-components=1

# Ensure ORACLE_HOME is clean before the installer runs
RUN mkdir -p ${ORACLE_HOME} && \
    rm -rf ${ORACLE_HOME}/* && \
    rm -rf ${ORACLE_HOME}/.[!.]*



# 2. Install Fusion Middleware Infrastructure (WLS + EM)
RUN export PATH=$JAVA_HOME/bin:$PATH && \
    java -jar /tmp/${INFRA_INSTALLER} -silent -responseFile /tmp/infra.rsp -ignoreSysPrereqs -invPtrLoc /tmp/oraInst.loc

# 3. Install Forms and Reports (Dependencies are now met)
# Note: Infrastructure is installed, satisfying the WLS/EM prerequisite.
RUN chmod +x /tmp/${FR_INSTALLER} && \
    /tmp/${FR_INSTALLER} -silent -responseFile /tmp/fr.rsp -ignoreSysPrereqs -invPtrLoc /tmp/oraInst.loc

# 4. Generate Forms shared libraries (.so) required by WLS_FORMS / frmweb
# The silent install leaves only static archives (.a) under $ORACLE_HOME/lib.
# genshlib builds the corresponding shared objects used at runtime.
ENV PATH=${ORACLE_HOME}/bin:${PATH} \
    LD_LIBRARY_PATH=${ORACLE_HOME}/lib

RUN cd ${ORACLE_HOME}/lib && \
    for lib in \
      libiplsn libibfrmw libiffw libifcw libijcw libipfw libimffrmw \
      libiwfw libiwcw libitw libicw libsosdw libixw libiicw libiiiw libiqw \
    ; do \
      echo "=== Generating ${lib}.so.0 ==="; \
      if [ ! -f "${lib}.a" ]; then \
        echo "ERROR: missing ${lib}.a"; \
        exit 1; \
      fi; \
      rm -f "${lib}.so" "${lib}.so.0"; \
      ${ORACLE_HOME}/bin/genshlib "${ORACLE_HOME}/lib/${lib}.so.0"; \
    done && \
    for lib in \
      libiplsn libibfrmw libiffw libifcw libijcw libipfw libimffrmw \
      libiwfw libiwcw libitw libicw libsosdw libixw libiicw libiiiw libiqw \
    ; do \
      test -e "${ORACLE_HOME}/lib/${lib}.so.0" || (echo "MISSING after genshlib: $lib" && exit 1); \
    done && \
    ldd ${ORACLE_HOME}/bin/frmweb | grep "not found" && exit 1 || echo "OK: frmweb has no missing shared library dependencies"


# ====================================================================
# STAGE 2: FINAL - Creates a clean, runtime-ready image
# ====================================================================
FROM oraclelinux:9

# Set runtime environment variables
ENV JAVA_HOME=/u01/jdk \
    ORACLE_HOME=/u01/oracle \
    DOMAIN_HOME=/u01/oracle/user_projects/domains/base_domain \
    PATH=/u01/oracle/bin:/u01/jdk/bin:${PATH} \
    LD_LIBRARY_PATH=/u01/oracle/lib

# Runtime OS packages:
# - libaio / libnsl: required by Oracle Forms native libraries
# - gcc / make / binutils: keep toolchain available for genshlib / Forms shared libs
# - nano / net-tools: operational utilities (editor, ifconfig/netstat)
# - motif / libX11 / libXext / libXt / libXp: required by Reports engine (librw.so, librwu.so -> libXm.so.4)
USER root
RUN dnf install -y libaio libnsl gcc make binutils nano net-tools \
                   motif libX11 libXext libXt libXp && \
    dnf clean all

# GUI packages for the Configuration Wizard (Xvfb display + VNC access)
# - Xvfb: virtual X display (:99); x11vnc (EPEL): exposes the display on port 5900
# - xauth / xhost / dbus-x11: X11 authentication and session bus for Java AWT/Swing
# - libX* / fontconfig / dejavu fonts: required by the Java GUI of the wizard
# - twm / xinit / X11 utils: optional window manager and utilities (installed if available)
RUN dnf install -y oracle-epel-release-el9 && \
    dnf config-manager --enable ol9_developer_EPEL && \
    dnf install -y xorg-x11-server-Xvfb x11vnc xorg-x11-xauth xhost dbus-x11 \
                   libXext libXrender libXtst libXi fontconfig dejavu-sans-fonts && \
    dnf install -y --setopt=strict=0 xorg-x11-twm xorg-x11-xinit xorg-x11-utils xorg-x11-server-utils && \
    command -v Xvfb && command -v x11vnc && \
    dnf clean all


# Copy the installed software from the builder stage
COPY --from=builder ${JAVA_HOME} ${JAVA_HOME}
COPY --from=builder ${ORACLE_HOME} ${ORACLE_HOME}
COPY --from=builder /u01/app/oraInventory /u01/app/oraInventory

# Reports engine native libraries must resolve (fails the build if motif/X11 packages are missing)
RUN missing=$(for f in ${ORACLE_HOME}/lib/librw*.so; do ldd "$f" | grep 'not found'; done | sort -u) && \
    if [ -n "$missing" ]; then echo "Missing libraries for Reports:"; echo "$missing"; exit 1; fi && \
    echo "OK: librw*.so has no missing shared library dependencies"

# Final setup of the 'oracle' user for runtime
RUN groupadd -g 1000 oracle && useradd -u 1000 -g oracle -d /u01/oracle -s /bin/bash oracle && \
    chown -R oracle:oracle /u01

# Copy domain creation and startup scripts
#COPY ./create_domain.py /u01/oracle/create_domain.py
#COPY ./start_server.sh /u01/oracle/start_server.sh

# Give execution permissions to the startup script
#RUN chmod +x /u01/oracle/start_server.sh && \
#    chmod +x /u01/oracle/create_domain.py

# Ensure all application files are owned by the oracle user
RUN chown -R oracle:oracle /u01

# Final configuration and entrypoint (Needs domain creation script)
# You must now add your custom script to create the domain and start the server.
USER oracle
WORKDIR ${ORACLE_HOME}
# CMD ["/u01/oracle/startDomain.sh"]
