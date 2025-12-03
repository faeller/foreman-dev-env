#!/bin/sh
# candlepin entrypoint: fix permissions then run as tomcat user
set -e

# fix /var/lib/candlepin ownership for artemis broker
chown -R tomcat:tomcat /var/lib/candlepin

# drop privileges and run catalina
exec runuser -u tomcat -- /opt/tomcat/bin/catalina.sh run
