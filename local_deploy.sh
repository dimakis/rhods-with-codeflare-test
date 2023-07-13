#! /bin/bash

set -e -o pipefail


function oc::wait::object::availability() {
    local cmd=$1 # Command whose output we require
    local interval=$2 # How many seconds to sleep between tries
    local iterations=$3 # How many times we attempt to run the command

    ii=0

    while [ $ii -le $iterations ]
    do

        token=$($cmd) && returncode=$? || returncode=$?
        if [ $returncode -eq 0 ]; then
            break
        fi

        ((ii=ii+1))
        if [ $ii -eq 100 ]; then
            echo $cmd "did not return a value"
            exit 1
        fi
        sleep $interval
    done
    echo $token
}

function oc::object::safe::to::apply() {
  local kind=$1
  local resource=$2
  local label="opendatahub.io/modified=false"

  local object="${kind}/${resource}"

  exists=$(oc get -n $ODH_PROJECT ${object} -o name | grep ${object} || echo "false")
  original=$(oc get -n $ODH_PROJECT ${kind} -l ${label} -o name | grep ${object} || echo "false")
  if [ "$exists" == "false" ]; then
    return 0
  fi

  if [ "$original" == "false" ]; then
    return 1
  fi

  return 0
}


ODH_PROJECT=${ODH_CR_NAMESPACE:-"redhat-ods-applications"}
ODH_MONITORING_PROJECT=${ODH_MONITORING_NAMESPACE:-"redhat-ods-monitoring"}
ODH_NOTEBOOK_PROJECT=${ODH_NOTEBOOK_NAMESPACE:-"rhods-notebooks"}
ODH_OPERATOR_PROJECT=${OPERATOR_NAMESPACE:-"redhat-ods-operator"}
NAMESPACE_LABEL="opendatahub.io/generated-namespace=true"
POD_SECURITY_LABEL="pod-security.kubernetes.io/enforce=baseline"

RHODS_SELF_MANAGED=0

# Apply specific configuration for OSD environments
if [ "$RHODS_SELF_MANAGED" -eq 0 ]; then

  echo "INFO: Applying specific configuration for OSD environments."

  # Give dedicated-admins group CRUD access to ConfigMaps, Secrets, ImageStreams, Builds and BuildConfigs in select namespaces
#   for target_project in ${ODH_PROJECT} ${ODH_NOTEBOOK_PROJECT}; do
#     oc apply -n $target_project -f rhods-osd-configs.yaml
#     if [ $? -ne 0 ]; then
#       echo "ERROR: Attempt to create the RBAC policy for dedicated admins group in $target_project failed."
#       exit 1
#     fi
#   done

  # Configure Dead Man's Snitch alerting
  deadmanssnitch=$(oc::wait::object::availability "oc get secret -n $ODH_MONITORING_PROJECT redhat-rhods-deadmanssnitch -o jsonpath='{.data.SNITCH_URL}'" 4 90 | tr -d "'"  | base64 --decode)
  echo $deadmanssnitch
  if [ -z "$deadmanssnitch" ];then
      echo "ERROR: Dead Man Snitch secret does not exist."
      exit 1
  fi
  sed -i '' "s#<snitch_url>#$deadmanssnitch#g" monitoring/prometheus/prometheus-configs.yaml

  # Configure PagerDuty alerting
  redhat_rhods_pagerduty=$(oc::wait::object::availability "oc get secret redhat-rhods-pagerduty -n $ODH_MONITORING_PROJECT" 5 60 )
  if [ -z "$redhat_rhods_pagerduty" ];then
      echo "ERROR: Pagerduty secret does not exist."
      exit 1
  fi
  pagerduty_service_token=$(oc::wait::object::availability "oc get secret redhat-rhods-pagerduty -n $ODH_MONITORING_PROJECT -o jsonpath='{.data.PAGERDUTY_KEY}'" 5 10)
  pagerduty_service_token=$(echo -ne "$pagerduty_service_token" | tr -d "'" | base64 --decode)
  sed -i '' "s/<pagerduty_token>/$pagerduty_service_token/g" monitoring/prometheus/prometheus-configs.yaml

  # Configure SMTP alerting
  redhat_rhods_smtp=$(oc::wait::object::availability "oc get secret redhat-rhods-smtp -n $ODH_MONITORING_PROJECT" 5 60 )
  if [ -z "$redhat_rhods_smtp" ];then
      echo "ERROR: SMTP secret does not exist."
      exit 1
  fi
  sed -i '' "s/<smtp_host>/$(oc::wait::object::availability "oc get secret -n $ODH_MONITORING_PROJECT redhat-rhods-smtp -o jsonpath='{.data.host}'" 2 30 | tr -d "'"  | base64 --decode)/g" monitoring/prometheus/prometheus-configs.yaml
  sed -i '' "s/<smtp_port>/$(oc::wait::object::availability "oc get secret -n $ODH_MONITORING_PROJECT redhat-rhods-smtp -o jsonpath='{.data.port}'" 2 30 | tr -d "'"  | base64 --decode)/g" monitoring/prometheus/prometheus-configs.yaml
  sed -i '' "s/<smtp_username>/$(oc::wait::object::availability "oc get secret -n $ODH_MONITORING_PROJECT redhat-rhods-smtp -o jsonpath='{.data.username}'" 2 30 | tr -d "'"  | base64 --decode)/g" monitoring/prometheus/prometheus-configs.yaml
  sed -i '' "s/<smtp_password>/$(oc::wait::object::availability "oc get secret -n $ODH_MONITORING_PROJECT redhat-rhods-smtp -o jsonpath='{.data.password}'" 2 30 | tr -d "'"  | base64 --decode)/g" monitoring/prometheus/prometheus-configs.yaml

  # Configure the SMTP destination email
  addon_managed_odh_parameter=$(oc::wait::object::availability "oc get secret addon-managed-odh-parameters -n $ODH_OPERATOR_PROJECT" 5 60 )
  if [ -z "$addon_managed_odh_parameter" ];then
      echo "ERROR: Addon managed odh parameter secret does not exist."
      exit 1
  fi
  sed -i '' "s/<user_emails>/$(oc::wait::object::availability "oc get secret -n $ODH_OPERATOR_PROJECT addon-managed-odh-parameters -o jsonpath='{.data.notification-email}'" 2 30 | tr -d "'"  | base64 --decode)/g" monitoring/prometheus/prometheus-configs.yaml


  # Configure the SMTP sender email
  if [[ "$(oc get route -n openshift-console console --template={{.spec.host}})" =~ .*"devshift.org".* ]]; then
    sed -i '' "s/redhat-openshift-alert@devshift.net/redhat-openshift-alert@rhmw.io/g" monitoring/prometheus/prometheus-configs.yaml
  fi

  if [[ "$(oc get route -n openshift-console console --template={{.spec.host}})" =~ .*"aisrhods".* ]]; then
    echo "Cluster is for RHODS engineering or test purposes. Disabling SRE alerting."
    sed -i '' "s/receiver: PagerDuty/receiver: alerts-sink/g" monitoring/prometheus/prometheus-configs.yaml
  else
    echo "Cluster is not for RHODS engineering or test purposes."
  fi

  # Configure Prometheus
  oc apply -n $ODH_MONITORING_PROJECT -f monitoring/prometheus/alertmanager-svc.yaml
  alertmanager_host=$(oc::wait::object::availability "oc get route alertmanager -n $ODH_MONITORING_PROJECT -o jsonpath='{.spec.host}'" 2 30 | tr -d "'")
  sed -i '' "s/<set_alertmanager_host>/$alertmanager_host/g" monitoring/prometheus/prometheus.yaml

  sed -i '' "s/<alertmanager_proxy_secret>/$(openssl rand -hex 32)/g" monitoring/prometheus/prometheus-secrets.yaml

  sed -i '' "s/<prometheus_proxy_secret>/$(openssl rand -hex 32)/g" monitoring/prometheus/prometheus-secrets.yaml
  oc create -n $ODH_MONITORING_PROJECT -f monitoring/prometheus/prometheus-secrets.yaml || echo "INFO: Prometheus session secrets already exist."

  oc apply -f monitoring/rhods-dashboard-route.yaml -n $ODH_PROJECT
  rhods_dashboard_host=$(oc::wait::object::availability "oc get route rhods-dashboard -n $ODH_PROJECT -o jsonpath='{.spec.host}'" 2 30 | tr -d "'")
  sed -i '' "s/<rhods_dashboard_host>/$rhods_dashboard_host/g" monitoring/prometheus/prometheus-configs.yaml

  notebook_spawner_host="notebook-controller-service.$ODH_PROJECT.svc:8080\/metrics,odh-notebook-controller-service.$ODH_PROJECT.svc:8080\/metrics"
  sed -i '' "s/<notebook_spawner_host>/$notebook_spawner_host/g" monitoring/prometheus/prometheus-configs.yaml

  data_science_pipelines_operator_host="data-science-pipelines-operator-service.$ODH_PROJECT.svc:8080\/metrics"
  sed -i '' "s/<data_science_pipelines_operator_host>/$data_science_pipelines_operator_host/g" monitoring/prometheus/prometheus-configs.yaml

  oc apply -n $ODH_MONITORING_PROJECT -f monitoring/prometheus/prometheus-configs.yaml

  alertmanager_config=$(oc get cm alertmanager -n $ODH_MONITORING_PROJECT -o jsonpath='{.data.alertmanager\.yml}' | openssl dgst -binary -sha256 | openssl base64)
  sed -i '' "s#<alertmanager_config_hash>#$alertmanager_config#g" monitoring/prometheus/prometheus.yaml

  prometheus_config=$(oc get cm prometheus -n $ODH_MONITORING_PROJECT -o jsonpath='{.data}' | openssl dgst -binary -sha256 | openssl base64)
  sed -i '' "s#<prometheus_config_hash>#$prometheus_config#g" monitoring/prometheus/prometheus.yaml
  oc apply -n $ODH_MONITORING_PROJECT -f monitoring/prometheus/prometheus.yaml

  sed -i '' "s#<odh_monitoring_project>#$ODH_MONITORING_PROJECT#g" monitoring/prometheus/prometheus-viewer-rolebinding.yaml
  oc apply -n $ODH_PROJECT -f monitoring/prometheus/prometheus-viewer-rolebinding.yaml

  # Configure Blackbox exporter
  oc apply -n $ODH_MONITORING_PROJECT -f monitoring/prometheus/blackbox-exporter-common.yaml

  if [[ "$(oc get route -n openshift-console console --template={{.spec.host}})" =~ .*"redhat.com".* ]]; then
    oc apply -f monitoring/prometheus/blackbox-exporter-internal.yaml -n $ODH_MONITORING_PROJECT
  else
    oc apply -f monitoring/prometheus/blackbox-exporter-external.yaml -n $ODH_MONITORING_PROJECT
  fi
fi