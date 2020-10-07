#!/bin/bash

err () {
    echo "$*" >&2
}

# Send a curl statement to retrieve the cluster name from the specified host.
getClusterName(){
    
    #Get cluster info
    requeststatus=$(curl -ivk -H "X-Requested-By: $user" -u $user:"$password" https://$hostport/api/v1/clusters/ 2>&1)
    #Handle errors with curl
    if ! echo "$requeststatus" | grep -i -q -E "HTTP.* 2[0-9]{2}"
    then 
        if echo "$requeststatus" | grep -i -q "Bad Credentials\|Invalid username/password combination\|Authentication Requested"
        then
            err "ERROR: Access Denied - Bad Credentials."
            exit 1
        elif echo "$requeststatus" | grep -i -q "Connection refused"
        then
            err "ERROR: Connection refused to port: $(echo $1 | grep -e "[0-9]$")"
            exit 1
        elif echo "$requeststatus" | grep -i -q "Couldn't resolve host"
        then
            err "ERROR: Could not resolve host: $(echo $1 | grep -i -e "^[a-z0-9\.]"). Check the hostname and try again."
            exit 1 
        else
            err "Unknown curl error: $requeststatus"
            exit 1
        fi
    fi

    #Get the cluster name from the successful response
    echo $(echo "$requeststatus" | grep -e "cluster_name" | cut -d '"' -f 4)
}

# $1 is the response grepped for HTTP 
checkHTTPCode () {
    responseCode=$(echo $1 | awk '{print $2}')
    if [[ $responseCode -eq 403 ]] || [[ $responseCode -eq 401 ]]; then
        echo ERROR: Incorrect Username/Password combination - Exiting...
        exit 1
    elif [[ $responseCode -ne 200 ]]; then
        echo -e "ERROR: Unknown HTTP error:\n$1"
        echo Exiting...
        exit 1
    fi
}

#$1 = host 
genHostQuery() {
    #If components is already set, we don't need to see what components the host has
    if [[ -z "$components" ]] ; then
    #Get a comma-delimited list of component names, filter out clients
    components=$(curl -s -k -u $user:"$password" -H "X-Requested-By: $user"  https://$hostport/api/v1/clusters/$cluster/hosts/$host/host_components/ | grep component_name | grep -v -e "\(SQOOP\|SLIDER\|PIG\|HCAT\|CLIENT\)" | cut -d '"' -f 4 | tr '\n' ',' | sed 's/,$//')
    fi
    hostquery="(HostRoles/component_name.in($components)&HostRoles/host_name=$host)"

    err $components for $host
    echo $hostquery
}

        genQueryBody() {
            query=""
            for host in $(cat $inFile); do
                #Add a | character to the query string to link the queries for each host with an or logical operator
                if [[ $query != "" ]]; then
                    query="$query|"
                fi
                if [[ $testing == "true" ]]; then
                    err "Would have performed operation \"$operation\" on $host"
                fi
                query="${query}$(genHostQuery $host)"
            done

            echo $query
        }

genBulkHostStartStopBody() {
    query=$(genQueryBody)
    # Add host context if there's only 1 host (only last bit of hostname for brevity
    hostcount=$(cat $inFile | grep "aetna.com" | wc -l)
    if [[ $hostcount -eq 1 ]]; then 
        hostContext=$(grep -oE '[mw][0-9]+[a-z]' $inFile)
        contextPrefix="$hostContext - "
    fi
    case $operation in
        start)
            statekey="state"
            stateval="STARTED"
            context="${contextPrefix}Start"
            ;;
        stop)
            statekey="state"
            stateval="INSTALLED"
            context="${contextPrefix}Stop"
            ;;
        maintenance_on)
            statekey="maintenance_state"
            stateval="ON"
            context="Maintenance mode on for"
            ;;
        maintenance_off)
            statekey="maintenance_state"
            stateval="OFF"
            context="Maintenance mode off for"
            ;;
    esac
    body="
{\"RequestInfo\" : {
    \"context\": \"$context all components via Bulk Host Action Script - $user ($(logname))\",
        \"operation_level\" : {
            \"level\" : \"CLUSTER\",
            \"cluster_name\" : \"$cluster\"
        },
        \"query\" : \"$query\"
    },
    \"Body\" : {
        \"HostRoles\" : {
            \"$statekey\" : \"$stateval\"
        }
    }
}"
    echo $body
}

# Change inFile to the file that hosts will be read from
# Format of the file is one line per host; no delimiter; ensure host names are FDQNs

# Invoke script with bash bulk_host_action.sh action
# where action is one of the commands in the case statement below:
#   delete - delete hosts
#   maintenance_on - turn on maintenance mode for hosts
#   maintenance_off - turn off maintenance mode for hosts
#   start - start all services on hosts
#   stop - stop all services on hosts

#Set default parameters
ssl=true
user=$USER
password=""
inFile="hosts"
testing=false
cluster=""

args=$(getopt -l "help,hostport:" -o "itf:h:c:u:p::o:" -- "$@")
eval set -- "$args"
#Process command line parameters
while [ $# -ge 1 ]; do
    case "$1" in 
        --)
            #No more options left
            shift
            break
            ;;
        --hostport|-h)
            hostport="$2"
            shift 
            ;;
        -u)
            user="$2"
            shift 
            ;;
        -p)
            password="$2"
            shift 
            ;;
        -c)
            cluster="$2"
            shift 
            ;; 
        -i)
            #-i for insecure (not https)
            ssl=false
            shift
            ;;
        -o)
            #Should be one of the following: delete, stop, start - ensure lowercase:
            operation=$(echo $2 | awk '{print tolower($1)}')
            shift 
            ;;
        -f)
            inFile="$2"
            shift 
            ;;
        -t)
            #testing param for a dry run
            testing=true
            shift
            ;;
        --help)
            echo "Usage: $0 -h 'ambari.aetna.com:port' -u 'username' -p 'password' -o 'operation' [ -c 'CLUSTER_NAME' -f 'hosts.txt' -i -t]"
            echo "Perform an action on a list of hosts via the Ambari API."
            echo "-h, --hostport    Specify the host and port of the Ambari server to run the checks on."
            echo "          Example: xhadmonm1d.aetna.com"
            echo "-u        Specify the username to send to Ambari server."
            echo "-p        Optional. Specify the password for the username. Do not specify to be prompted interactively."
            echo "-c        Optional. Specify the cluster name (HATHI,DBAR_HATHI,DEV_HATHI...)."
            echo "-o        Specify the operation to perform on all of the hosts."
            echo "          Valid options are the following: start, stop, maintenance_on, maintenance_off"
            echo "-t        Optional. Do a dry-run; do not perform any action."
            echo "-i        Optional. Use http instead of the default https"
            echo "-f        Optional. Specify the file to read the target hosts from. Each FQDN should be on it's own line. Default is hosts.txt"
            echo "--help        Display this help."
            echo "Example usage to stop all components in a file myhosts.txt: $0 -u admin -p password -h xhadmonm1d.aetna.com:8443 -o stop -f myhosts.txt"
            echo "Contact iacobaccia@aetna.com with any questions."
            exit 0
            ;;
        *)
           echo "Invalid command: $1. --help for help." 
           shift
           ;;
    esac 
    shift
done



# File name is now accepted as argument

if [[ ! -f "$inFile" ]]; then
    echo "File $inFile does not exist"
    exit 1
elif [[ ! -s "$inFile" ]]; then 
    echo "File $inFile is empty"
fi

if [[ -z "$operation" ]]; then
    echo "Please include an operation with the -o option!"
    echo "Possible operations are delete, stop, start"
    exit 1
fi  

if [[ -z "$hostport" ]]; then
    if [[ $(hostname -f) =~ .*mon.* ]]; then
        hostport="$(hostname -f):8443"
        err "Hostname and port not supplied, guessing it is $hostport..."
    else
        err "Hostname and port not supplied, please include hostname and port with the -h option!"
    fi
fi

if [[ -z "$password" ]];then
    read -s -p "Enter password for $user: " password
    echo ""
fi

#Check Password
response=$(curl -sI -u $user:"$password" https://$hostport/api/v1/clusters/ 2>/dev/null | grep HTTP)
checkHTTPCode "$response"

if [[ -z "$cluster" ]]; then
    cluster=$(getClusterName)
    echo "Automatically discovered cluster: $cluster"
fi

if [[ $operation == "delete" && $testing == "false" ]]; then

    echo "Hosts to be deleted: "
    cat $inFile | sed 's/^/\t/'
    read -p "Are you sure you want to delete these hosts?[y/n]: " confirm

    confirm=$(echo $confirm | awk '{print tolower($1)}')

    if [[ $confirm == 'n' ]]; then
        exit 0
    elif [[ $confirm == 'y' ]]; then
        echo "Proceeding with deletion of hosts..."
    else
        echo "Please enter either 'y' or 'n'."
        exit 1
    fi
fi

if [[ $operation == "stop" ]] || [[ $operation == "stop_nodemanager" ]]; then
    if [[ $operation == "stop_nodemanager" ]]; then 
        components=NODEMANAGER
    fi
    for operation in "stop" "maintenance_on"; do
        payload=$(genBulkHostStartStopBody)
        if [[ $testing == "true" ]]; then
            echo "Would have sent the previous operations to https://$hostport/api/v1/clusters/$cluster/host_components?"
            echo $payload
        else
            #send payload
            curl -s -k -u $user:"$password" -H "X-Requested-By: $user" -d "$payload" -X PUT https://$hostport/api/v1/clusters/$cluster/host_components?
        fi
    done
fi

if [[ $operation == "start" ]]; then
    for operation in "maintenance_off" "start"; do
        payload=$(genBulkHostStartStopBody)
        if [[ $testing == "true" ]]; then
            echo "Would have sent the previous operations to https://$hostport/api/v1/clusters/$cluster/host_components?"
            echo $payload
        else
            #send payload
            curl -s -k -u $user:"$password" -H "X-Requested-By: $user" -d "$payload" -X PUT https://$hostport/api/v1/clusters/$cluster/host_components?
        fi
    done
fi

#delete maintenance_on,off
if [[ $operation == "delete" ]]; then
    level="component"
    for host in $(cat $inFile); do
        case "$operation" in
            delete)
                echo "DELETE OPERATION for $host"
                ;;
            #Not currently working
            custom)
                echo "CUSTOM COMMAND FOR $host"
                body="$2"
                level="$3"
                ;;
            *)
                echo "Invalid command: $1. --help for help."
                ;; 
        esac
        
        if [[ $level != "host" ]]; then
            echo "Getting components for ${host}..."
            #Get a comma-delimited list of component names, filter out clients
            components=`curl -s -k -u $user:"$password" -H "X-Requested-By: $user"  https://$hostport/api/v1/clusters/$cluster/hosts/$host/host_components/ | grep component_name | grep -v "CLIENT" | cut -d '"' -f 4 | tr '\n' ',' | sed 's/,$//'`
            #Convert back to a list of components on their own lines for deletion operation
            if [[ $operation == "delete" ]]; then 
                #Get list of components for the host
                components=`curl -s -k -u $user:"$password" -H "X-Requested-By: $user"  https://$hostport/api/v1/clusters/$cluster/hosts/$host/host_components/ | grep component_name | cut -d '"' -f 4`
                if [[ $testing == "true" ]]; then 
                    echo "Would have deleted the components from $host"
                else
                    for i in $(echo $components | tr ',' '\n'); do
                        echo Deleting $i from $host
                        curl -s -k -u $user:"$password" -H "X-Requested-By: $user" -X DELETE https://$hostport/api/v1/clusters/$cluster/hosts/$host/host_components/$i
                    done;
                fi
            else
                #Get a comma-delimited list of component names, filter out clients
                components=`curl -s -k -u $user:"$password" -H "X-Requested-By: $user"  https://$hostport/api/v1/clusters/$cluster/hosts/$host/host_components/ | grep component_name | grep -v "CLIENT" | cut -d '"' -f 4 | tr '\n' ',' | sed 's/,$//'`
                #Substitute in the list of components to stop
                body_subbed=$(echo $body | sed "s/HOST_COMPONENT_LIST/$components/")
                if [[ $testing == "true" ]]; then
                    echo "Would have sent $body_subbed to https://$hostport/api/v1/clusters/$cluster/hosts/$host/host_components?"
                else 
                    echo "Sending $operation to $host"
                    curl -s -k -u $user:"$password" -H "X-Requested-By: $user" -d "$body_subbed" -X PUT https://$hostport/api/v1/clusters/$cluster/hosts/$host/host_components?
                fi
            fi
        else
            if [[ ! $testing == "true" ]]; then
                #Host level operations
                curl -s -k -u $user:"$password" -H "X-Requested-By: $user" -d "$body" -X PUT https://$hostport/api/v1/clusters/$cluster/hosts/$host/
            fi
        fi
        #Run delete for host with all components stopped and deleted now, if operation is delete
        if [[ $operation == "delete" ]]; then
            if [[ $testing == "true" ]] ; then
                echo "Would have deleted $host."
            else
                echo Deleting host: $host 
                curl -s -k -u $user:"$password" -H "X-Requested-By: $user" -X DELETE https://$hostport/api/v1/clusters/$cluster/hosts/$host
            fi        
        fi
    done;
fi
