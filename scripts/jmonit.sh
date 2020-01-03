#!/bin/bash

[ -z "$JORMUNGANDR_CLI" ] && JORMUNGANDR_CLI="./jcli"
[ -z "$JORMUNGANDR_RESTAPI_URL" ] && JORMUNGANDR_RESTAPI_URL="http://127.0.0.1:3101/api"

POOL_ID=$(cat stake_pool.id 2>/dev/null)

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
BLOCK_HEIGHT_DELTA_LIMIT=5
LEADER_DELTA_LIMIT=300
SCHEDULED_AT_TIME=""

function log {
	MESSAGE=$1
	if [ $# -eq 2 ]; then
		COLOR=$2
	else
		COLOR=$COLOR_NC
	fi
	echo -e "$(date +'%Y-%m-%d %H:%M:%S') - ${COLOR}${MESSAGE}${COLOR_NC}"
}

function save_to_log {
	echo -e "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
	echo "" >> $LOG_FILE
}

function start_node {
	log "Starting jormungandr" $COLOR_WARN
	service jormungandr start
}

function stop_node {
	log "Stopping jormungandr" $COLOR_WARN
	service jormungandr stop
}

function restart_node {
	log "Restarting jormungandr" $COLOR_WARN
	service jormungandr restart
}

while true
do
	NODE_STATS=$($JORMUNGANDR_CLI rest v0 node stats get -h $JORMUNGANDR_RESTAPI_URL 2>/dev/null)
	if [ -z "$NODE_STATS" ]; then
		if [ $NODE_ERROR -lt 6 ] && [ -f "$JORMUNGANDR_CLI" ]; then
			((NODE_ERROR++))
			log "The jormungandr is not active, trying to start - ${NODE_ERROR}" $COLOR_WARN
			LAST_BLOCK_HEIGHT=0
			start_node
		else
			log "An error occurred while running the jormungandr" $COLOR_ERROR
			exit
		fi	
	else
		NODE_ERROR=0
		CURRENT_BLOCK_HEIGHT=$(echo "$NODE_STATS" | grep 'lastBlockHeight' | grep -P -o '[0-9]+')

		if [ ! -z "$CURRENT_BLOCK_HEIGHT" ]; then
			TIME_NOW=$(date +%s)
			
			LEADERS_LOGS=$($JORMUNGANDR_CLI rest v0 leaders logs get -h $JORMUNGANDR_RESTAPI_URL 2>/dev/null)
			
			LEADERS_SCHEDULED_AT_TIME=$(echo "$LEADERS_LOGS" | grep "scheduled_at_time");
			
			if [ ! -z "$LEADERS_SCHEDULED_AT_TIME" ]; then
				if [ ! -z "$SCHEDULED_AT_TIME" ]; then
					LAST_HASH=$(echo "$LEADERS_LOGS" | grep "scheduled_at_time: \"$SCHEDULED_AT_TIME\"" -A 5 | grep "block: " | awk '{print $2}')
					
					if [ ! -z "$LAST_HASH" ]; then
						STEP=1
						while [ $STEP -le 5 ]
						do
							CHECK_POOL=$(curl -s 'https://explorer.incentivized-testnet.iohkdev.io/explorer/graphql' -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:71.0) Gecko/20100101 Firefox/71.0' -H 'content-type: application/json' -H 'referer: https://shelleyexplorer.cardano.org/en/block/$LAST_HASH' -H 'Accept-Language: en-US,en;q=0.5' --data-binary '{"query":"\n      query {\n        block (id:\"$LAST_HASH\") {\n          \n  leader {\n    __typename\n    ... on Pool {\n      \n  id\n      }\n  }\n\n        }\n      }\n    "}' | grep "$POOL_ID")
							if [ -z "$CHECK_POOL" ]; then
								STEP=$(( $STEP + 1 ))
								sleep STEP
							else
								break;
							fi
						done
						
						if [ -z "$CHECK_POOL" ]; then
							log "The block $LAST_HASH was generated by another node" $COLOR_ERROR
						else
							log "The block $LAST_HASH was generated by node" $COLOR_INFO
						fi
					fi
					
					SHOW_NEXT_BLOCK=1
				else
					SHOW_NEXT_BLOCK=0
				fi
				
				LEADER_DELTA=99999999
				SCHEDULED_AT_TIME=""
				while read -r line; do
					if [ "$(uname -s)" == "Darwin" ]; then
						TIME_LEADER=$(date -ju -f "%FT%T+00:00" $line +%s 2>/dev/null)
					else
						TIME_LEADER=$(date -d $line +%s 2>/dev/null)
					fi
					LEADER_DELTA_NEW=$(($TIME_LEADER - $TIME_NOW))
					
					if [[ $LEADER_DELTA_NEW -lt $LEADER_DELTA ]]; then
						LEADER_DELTA=$LEADER_DELTA_NEW
						SCHEDULED_AT_TIME=$line
					fi
				done <<< $(echo "$LEADERS_LOGS" | grep -iF "status: pending" -B 3 | grep "scheduled_at_time" | awk -F '"' '{print $2}')
				
				if [[ $LEADER_DELTA -lt $LEADER_DELTA_LIMIT ]]; then
					LEADER_DELTA=$(($LEADER_DELTA + 5))
					if [[ $LEADER_DELTA -lt $SLEEP_INTERVAL ]]; then
						LEADER_DELTA=$SLEEP_INTERVAL
					fi
					log "Waiting ${LEADER_DELTA} sec for the slot leader"
					sleep $LEADER_DELTA
					continue
				else
					if [ $SHOW_NEXT_BLOCK -gt 0 ] && [ ! -z "$SCHEDULED_AT_TIME" ]; then
						log "The next block will be at $SCHEDULED_AT_TIME"
					fi
					SCHEDULED_AT_TIME=""
				fi
			fi
		
			LAST_BLOCK_TIME=$(echo "$NODE_STATS" | grep 'lastBlockTime' | awk -F '"' '{print $2}')
			LAST_RECEIVED_BLOCK_TIME=$(echo "$NODE_STATS" | grep 'lastReceivedBlockTime' | awk -F '"' '{print $2}')
			if [ "$(uname -s)" == "Darwin" ]; then
				CURRENT_BLOCK_TIME=$(date -ju -f "%FT%T+00:00" $LAST_BLOCK_TIME +%s 2>/dev/null)
				CURRENT_RECEIVED_BLOCK_TIME=$(date -ju -f "%FT%T+00:00" $LAST_RECEIVED_BLOCK_TIME +%s 2>/dev/null)
			else
				CURRENT_BLOCK_TIME=$(date -d $LAST_BLOCK_TIME +%s 2>/dev/null)
				CURRENT_RECEIVED_BLOCK_TIME=$(date -d $LAST_RECEIVED_BLOCK_TIME +%s 2>/dev/null)
			fi
			TEMP_GLOBAL_BLOCK_HEIGHT=$(curl -s 'https://explorer.incentivized-testnet.iohkdev.io/explorer/graphql' -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:71.0) Gecko/20100101 Firefox/71.0' -H 'content-type: application/json' -H 'referer: https://shelleyexplorer.cardano.org/en/blocks/' -H 'Accept-Language: en-US,en;q=0.5' --data-binary '{"query":"\n    query {\n      allBlocks (last: 1) {\n        \n  pageInfo {\n    endCursor\n  }\n\n        }\n    }\n  "}' | sed -n 's|.*"endCursor":"\([^"]*\)".*|\1|p')
			if [[ $GLOBAL_BLOCK_HEIGHT -lt $TEMP_GLOBAL_BLOCK_HEIGHT ]]; then
				GLOBAL_BLOCK_HEIGHT=$TEMP_GLOBAL_BLOCK_HEIGHT
			fi
			BLOCK_HEIGHT_DELTA=$(($GLOBAL_BLOCK_HEIGHT - $CURRENT_BLOCK_HEIGHT))
			TIME_DELTA=$(($CURRENT_RECEIVED_BLOCK_TIME - $CURRENT_BLOCK_TIME))
			
			if [[ $BLOCK_HEIGHT_DELTA_LIMIT -lt $BLOCK_HEIGHT_DELTA ]]; then
				log "Error block height: ${CURRENT_BLOCK_HEIGHT}, global block height: ${GLOBAL_BLOCK_HEIGHT}" $COLOR_ERROR
				restart_node
				save_to_log "block height\n$NODE_STATS\n$CURRENT_BLOCK_HEIGHT - $GLOBAL_BLOCK_HEIGHT"
			elif [[ $TIME_DELTA_LIMIT -lt $TIME_DELTA ]]; then
				log "Error block time: ${LAST_BLOCK_TIME}, global block time: ${LAST_RECEIVED_BLOCK_TIME}" $COLOR_ERROR
				restart_node
				save_to_log "block time\n$NODE_STATS\n$LAST_BLOCK_TIME - $LAST_RECEIVED_BLOCK_TIME"
			elif [[ $LAST_BLOCK_HEIGHT -lt $CURRENT_BLOCK_HEIGHT ]]; then
				LAST_BLOCK_HEIGHT=$CURRENT_BLOCK_HEIGHT
				TIME_CHECK=$TIME_NOW
				log "New block height is ${CURRENT_BLOCK_HEIGHT}" $COLOR_INFO
			else
				ELAPSED_TIME=$(($TIME_NOW - $TIME_CHECK))
				if [[ $MAX_DURATION -lt $ELAPSED_TIME ]]; then
					log "No new block for ${ELAPSED_TIME} sec" $COLOR_ERROR
					restart_node
					save_to_log "stuck\n$ELAPSED_TIME - $MAX_DURATION\n$TIME_NOW - $TIME_CHECK"
				else
					log "No new block for ${ELAPSED_TIME} sec"
				fi
			fi
		else
			log "The node is bootstraping, please wait"
		fi	
	fi	
    sleep $SLEEP_INTERVAL
done

exit 0
