#! /bin/bash

CORESITEPATH=/etc/hadoop/conf/core-site.xml
AMBARICONFIGS_SH=/var/lib/ambari-server/resources/scripts/configs.sh
AMBARICONFIGS_PY=/var/lib/ambari-server/resources/scripts/configs.py
PORT=8080

WEBWASB_TARFILE=apache-tomcat-8.5.87.tar.gz
WEBWASB_TARFILEURI=https://dlcdn.apache.org/tomcat/tomcat-8/v8.5.87/bin/apache-tomcat-8.5.87.tar.gz
WEBWASB_TMPFOLDER=/home/WxAdminSc/tomcat
WEBWASB_INSTALLFOLDER=/usr/share/apache-tomcat-8.5.87

LOG_PREFIX='Install_TomeCat_Script'

function log() {
  local prefix=${LOG_PREFIX}
  local log_level=${1:-INFO}
  local msg=${2:-"Empty Msg"}
  echo "$(date +"%M-%d-%Y %H:%M:%S") [${prefix}]: ${log_level} ${msg}"
  if [[ "${log_level}" == "INFO" ]]; then
    logger -t ${prefix} -p user.info "${log_level} ${msg}"
  elif [[ "${log_level}" == "WARN" ]]; then
    logger -t ${prefix} -p user.warn "${log_level} ${msg}"
  elif [[ "${log_level}" == "ERROR" ]]; then
    logger -t ${prefix} -p user.err "${log_level} ${msg}"
  fi
}

function execute_with_logs(){
  local command_to_execute=${*}

  logs=$(eval ${command_to_execute} 2>&1)
  exit_code=${?}
  log INFO "Output of running '${command_to_execute}':"
  OLD_IFS=${IFS}
  # changing field separator so that we can read line by line in for loop
  IFS=$'\n'
  for l in ${logs}
  do
     log INFO "${l}"
  done
  IFS=${OLD_IFS}
  return ${exit_code}
}

OS_VERSION=$(lsb_release -sr)

ACTIVEAMBARIHOST=headnodehost

#Import helper module
wget -O /tmp/HDInsightUtilities-v01.sh -q https://hdiconfigactions.blob.core.windows.net/linuxconfigactionmodulev01/HDInsightUtilities-v01.sh && source /tmp/HDInsightUtilities-v01.sh && rm -f /tmp/HDInsightUtilities-v01.sh

usage() {
    echo ""
    echo "Usage: sudo -E bash install-TomeCat-uber-v02.sh";
    echo "This script does NOT require Ambari username and password";
    exit 132;
}

checkHostNameAndSetClusterName() {
    PRIMARYHEADNODE=`get_primary_headnode`
    SECONDARYHEADNODE=`get_secondary_headnode`
    PRIMARY_HN_NUM=`get_primary_headnode_number`
    SECONDARY_HN_NUM=`get_secondary_headnode_number`

    #Check if values retrieved are empty, if yes, exit with error
    if [[ -z $PRIMARYHEADNODE ]]; then
        log ERROR "Could not determine primary headnode."
        exit 139
    fi

    if [[ -z $SECONDARYHEADNODE ]]; then
        log ERROR "Could not determine secondary headnode."
        exit 140
    fi

    if [[ -z "$PRIMARY_HN_NUM" ]]; then
        log ERROR "Could not determine primary headnode number."
        exit 141
    fi

    if [[ -z "$SECONDARY_HN_NUM" ]]; then
        log ERROR "Could not determine secondary headnode number."
        exit 142
    fi

    fullHostName=$(hostname -f)
    log INFO "fullHostName=$fullHostName. Lower case: ${fullHostName,,}"
    log INFO "primary headnode=$PRIMARYHEADNODE. Lower case: ${PRIMARYHEADNODE,,}"
    if [ "${fullHostName,,}" != "${PRIMARYHEADNODE,,}" ]; then
        log ERROR "$fullHostName is not primary headnode. This script has to be run on $PRIMARYHEADNODE."
        exit 0
    fi
    CLUSTERNAME=$(sed -n -e 's/.*\.\(.*\)-ssh.*/\1/p' <<< $fullHostName)
    if [ -z "$CLUSTERNAME" ]; then
        CLUSTERNAME=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nprint ClusterManifestParser.parse_local_manifest().deployment.cluster_name" | python)
        if [ $? -ne 0 ]; then
            log ERROR "[ERROR] Cannot determine cluster name. Exiting!"
            exit 133
        fi
    fi
    log INFO "Cluster Name=$CLUSTERNAME"
}

validateUsernameAndPassword() {
    log INFO "Validate Ambari User Creds"
    coreSiteContent=$($AMBARICONFIGS_PY --user=$USERID --password=$PASSWD --action=get --port=$PORT --host=$ACTIVEAMBARIHOST --cluster=$CLUSTERNAME --config-type=core-site)
    if [[ $coreSiteContent == *"[ERROR]"* && $coreSiteContent == *"Bad credentials"* ]]; then
        log ERROR "[ERROR] Username and password are invalid. Exiting!"
        exit 134
    fi
}

updateAmbariConfigs() {
    updateResult=$($AMBARICONFIGS_PY --user=$USERID --password=$PASSWD --action=set --port=$PORT --host=$ACTIVEAMBARIHOST --cluster=$CLUSTERNAME --config-type=oozie-site -k "oozie.service.ProxyUserService.proxyuser.tomcat.hosts" -v "*")
    log INFO "UpdateResult for oozie-site: $updateResult"
    if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
        log ERROR "[ERROR] Failed to update oozie-site. Exiting!"
        log INFO $updateResult
        exit 135
    fi

    log INFO "Updated oozie.service.ProxyUserService.proxyuser.tomcat.hosts = *"

    updateResult=$($AMBARICONFIGS_PY --user=$USERID --password=$PASSWD --action=set --port=$PORT --host=$ACTIVEAMBARIHOST --cluster=$CLUSTERNAME --config-type=oozie-site -k "oozie.service.ProxyUserService.proxyuser.tomcat.groups" -v "*")
    log INFO "UpdateResult for oozie-site: $updateResult"
    if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
        log ERROR "[ERROR] Failed to update oozie-site. Exiting!"
        log INFO $updateResult
        exit 135
    fi

    log INFO "Updated oozie.service.ProxyUserService.proxyuser.tomcat.groups = *"
}

stopServiceViaRest() {
    if [ -z "$1" ]; then
        log ERROR "Need service name to stop service"
        exit 136
    fi
    SERVICENAME=$1
    log INFO "Stopping $SERVICENAME"
    execute_with_logs 'sudo python -c "from hdinsight_common.AmbariHelper import AmbariHelper; AmbariHelper().change_service_state("$SERVICENAME", 'INSTALLED')"'
    log INFO "Completed stopping $SERVICENAME"
}

startServiceViaRest() {
    if [ -z "$1" ]; then
        log ERROR "Need service name to start service"
        exit 136
    fi
    sleep 2
    SERVICENAME=$1
    log INFO "Starting $SERVICENAME"

    execute_with_logs 'sudo python -c "from hdinsight_common.AmbariHelper import AmbariHelper; AmbariHelper().change_service_state("$SERVICENAME", 'STARTED')"'
    log INFO "Completed starting $SERVICENAME"
}

restartStaleServices() {
    log INFO "Restarting All Stale Services"

sudo python <<EOF
from hdinsight_common.AmbariHelper import AmbariHelper
from hdinsight_common import hdinsightlogging
import datetime,inspect, sys, logging, traceback
from logging.handlers import SysLogHandler
logger = logging.getLogger(__name__)
hdinsightlogging.initialize_root_logger(syslog_facility=SysLogHandler.LOG_LOCAL2)

try:
    AmbariHelper().restart_all_stale_services()
    logger.info("[${LOG_PREFIX}]: Completed restarting all stale services")
except Exception as e:
    logger.error("[${LOG_PREFIX}]: Unable to restart all stale service {0}. Exception: {1}\n{2}".format("$SERVICENAME", repr(str(e)), repr(traceback.format_exc())))
EOF
}

downloadAndUnzipWebWasb() {
    log INFO "Removing WebWasb installation and tmp folder"
    execute_with_logs  "rm -rf $WEBWASB_INSTALLFOLDER/"
    execute_with_logs "rm -rf $WEBWASB_TMPFOLDER/"
    execute_with_logs "mkdir $WEBWASB_TMPFOLDER/"
    
    log INFO "Downloading webwasb tar file"
    wget $WEBWASB_TARFILEURI -P $WEBWASB_TMPFOLDER
    
    log INFO "Unzipping webwasb-tomcat"
    tar -zxvf $WEBWASB_TMPFOLDER/$WEBWASB_TARFILE -C /usr/share/
}

setupWebWasbService() {
    execute_with_logs "/usr/share/apache-tomcat-8.5.87/bin/startup.sh"
}



##############################
if [ "$(id -u)" != "0" ]; then
    log INFO "[ERROR] The script has to be run as root."
    usage
fi

USERID=$(echo -e "import hdinsight_common.Constants as Constants\nprint Constants.AMBARI_WATCHDOG_USERNAME" | python)

log INFO "USERID=$USERID"

PASSWD=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nimport hdinsight_common.Constants as Constants\nimport base64\nbase64pwd = ClusterManifestParser.parse_local_manifest().ambari_users.usersmap[Constants.AMBARI_WATCHDOG_USERNAME].password\nprint base64.b64decode(base64pwd)" | python)

export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64

echo JAVA_HOME=$JAVA_HOME

checkHostNameAndSetClusterName
validateUsernameAndPassword
log INFO "======== Updating Ambari Configs ============="
updateAmbariConfigs

log INFO "======== Downloading and unzip WebWasb and Hue ============="
downloadAndUnzipWebWasb

log INFO "======== Restarting Stale Services ============="
restartStaleServices

setupWebWasbService