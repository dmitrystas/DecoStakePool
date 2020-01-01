#!/bin/bash

[ -z "$JORMUNGANDR_CLI" ] && JORMUNGANDR_CLI="./jcli"
[ -z "$JORMUNGANDR_RESTAPI_URL" ] && JORMUNGANDR_RESTAPI_URL="http://127.0.0.1:3101/api"

LOG_FILE=./jmonit.log

COLOR_ERROR='\033[0;31m'
COLOR_INFO='\033[0;32m'
COLOR_WARN='\033[0;33m'
COLOR_NC='\033[0m'

NODE_ERROR=0

MAX_DURATION=600
SLEEP_INTERVAL=30

TIME_START=$(date +%s)
TIME_CHECK=$TIME_START

LAST_BLOCK_HEIGHT=0
GLOBAL_BLOCK_HEIGHT=0

TIME_DELTA_LIMIT=120
BLOCK_HEIGHT_DELTA_LIMIT=1
LEADER_DELTA_LIMIT=180

function start_node {
	service jormungandr start
	# echo Start node
}

function stop_node {
	service jormungandr stop
	# echo Stop node
}

function restart_node {
	service jormungandr restart
	# echo Restart node
}

while true
do
	NODE_STATS=$($JORMUNGANDR_CLI rest v0 node stats get -h $JORMUNGANDR_RESTAPI_URL 2>/dev/null)
	if [ -z "$NODE_STATS" ]; then
		if [ $NODE_ERROR -lt 6 ] && [ -f "$JORMUNGANDR_CLI" ]; then
			((NODE_ERROR++))
			echo -e "${COLOR_WARN}"
			echo -e "WARN: The jormungandr is not active, trying to start - ${NODE_ERROR}"
			echo -e "${COLOR_NC}"
			LAST_BLOCK_HEIGHT=0
			start_node
		else
			echo -e "${COLOR_ERROR}"
			echo -e "ERROR: an error occurred while running the jormungandr"
			echo -e "${COLOR_NC}"
			exit
		fi	
	else
		NODE_ERROR=0
		CURRENT_BLOCK_HEIGHT=$(echo "$NODE_STATS" | grep 'lastBlockHeight' | grep -P -o '[0-9]+')

		if [ ! -z "$CURRENT_BLOCK_HEIGHT" ]; then
			TIME_NOW=$(date +%s)
			
			LEADER_DELTA=0
			while read -r line; do
				TIME_LEADER=$(date -d $line +%s)
				LEADER_DELTA=$(($TIME_LEADER - $TIME_NOW))
				
				if [[ $LEADER_DELTA -lt $LEADER_DELTA_LIMIT ]]; then
					LEADER_DELTA=$(($LEADER_DELTA+5))
					if [[ $LEADER_DELTA -lt $SLEEP_INTERVAL ]]; then
						LEADER_DELTA=$SLEEP_INTERVAL
					fi
					break
				else
					LEADER_DELTA=0
				fi
			done <<< $($JORMUNGANDR_CLI rest v0 leaders logs get -h $JORMUNGANDR_RESTAPI_URL 2>/dev/null | grep -iF "status: pending" -B 3 | grep "scheduled_at_time" | awk -F '"' '{print $2}')
			
			if [[ $LEADER_DELTA -ne 0 ]]; then
				echo "$(date +'%Y-%m-%d %H:%M:%S') - Waiting ${LEADER_DELTA} sec for slot leader"
				sleep $LEADER_DELTA
				continue
			fi
		
			CURRENT_BLOCK_TIME=$(echo "$NODE_STATS" | grep 'lastBlockTime' | grep -P -o '(?<=T)(:?[0-9]{1,2}){3}' | awk -F ':' '{print $1*3600+$2*60+$3}')
			CURRENT_RECEIVED_BLOCK_TIME=$(echo "$NODE_STATS" | grep 'lastReceivedBlockTime' | grep -P -o '(?<=T)(:?[0-9]{1,2}){3}' | awk -F ':' '{print $1*3600+$2*60+$3}')
			TEMP_GLOBAL_BLOCK_HEIGHT=$(curl -s 'https://explorer.incentivized-testnet.iohkdev.io/explorer/graphql' -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:71.0) Gecko/20100101 Firefox/71.0' -H 'content-type: application/json' -H 'referer: https://shelleyexplorer.cardano.org/en/blocks/' -H 'Accept-Language: en-US,en;q=0.5' --data-binary '{"query":"\n    query {\n      allBlocks (last: 1) {\n        \n  pageInfo {\n    endCursor\n  }\n\n        }\n    }\n  "}' | sed -n 's|.*"endCursor":"\([^"]*\)".*|\1|p')
			if [[ $GLOBAL_BLOCK_HEIGHT -lt $TEMP_GLOBAL_BLOCK_HEIGHT ]]; then
				GLOBAL_BLOCK_HEIGHT=$TEMP_GLOBAL_BLOCK_HEIGHT
			fi
			BLOCK_HEIGHT_DELTA=$(($GLOBAL_BLOCK_HEIGHT - $CURRENT_BLOCK_HEIGHT))
			TIME_DELTA=$(($CURRENT_RECEIVED_BLOCK_TIME - $CURRENT_BLOCK_TIME))
			
			if [[ $BLOCK_HEIGHT_DELTA_LIMIT -lt $BLOCK_HEIGHT_DELTA ]]; then
				restart_node
				echo -e "${COLOR_WARN}Restarting jormungandr${COLOR_NC}"
				echo "$(date +'%Y-%m-%d %H:%M:%S') - block height" >> $LOG_FILE
				echo "$NODE_STATS" >> $LOG_FILE
				echo "$CURRENT_BLOCK_HEIGHT - $GLOBAL_BLOCK_HEIGHT" >> $LOG_FILE
				echo "" >> $LOG_FILE
			elif [[ $TIME_DELTA_LIMIT -lt $TIME_DELTA ]]; then
				restart_node
				echo -e "${COLOR_WARN}Restarting jormungandr${COLOR_NC}"
				echo "$(date +'%Y-%m-%d %H:%M:%S') - block time" >> $LOG_FILE
				echo "$NODE_STATS" >> $LOG_FILE
				echo "$CURRENT_BLOCK_TIME - $CURRENT_RECEIVED_BLOCK_TIME" >> $LOG_FILE
				echo "$TIME_DELTA - $TIME_DELTA_LIMIT" >> $LOG_FILE
				echo "" >> $LOG_FILE
			elif [[ $LAST_BLOCK_HEIGHT -lt $CURRENT_BLOCK_HEIGHT ]]; then
				LAST_BLOCK_HEIGHT=$CURRENT_BLOCK_HEIGHT
				TIME_CHECK=$TIME_NOW
				echo -e "$(date +'%Y-%m-%d %H:%M:%S') - ${COLOR_INFO}New block height: ${CURRENT_BLOCK_HEIGHT}${COLOR_NC}"
			else
				ELAPSED_TIME=$(($TIME_NOW - $TIME_CHECK))
				echo "$(date +'%Y-%m-%d %H:%M:%S') - No new block for ${ELAPSED_TIME} sec"
				if [[ $MAX_DURATION -lt $ELAPSED_TIME ]]; then
					restart_node
					echo -e "$(date +'%Y-%m-%d %H:%M:%S') - ${COLOR_WARN}Restarting jormungandr${COLOR_NC}"
					echo "$(date +'%Y-%m-%d %H:%M:%S') - stuck" >> $LOG_FILE
					echo "$ELAPSED_TIME - $MAX_DURATION" >> $LOG_FILE
					echo "$TIME_NOW - $TIME_CHECK" >> $LOG_FILE
					echo "" >> $LOG_FILE
				fi
			fi
		else
			echo "The node is bootstraping, please wait"
		fi	
	fi	
    sleep $SLEEP_INTERVAL
done

exit 0
