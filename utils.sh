#!/bin/bash

get_services()
{
    systemctl | grep running | grep service
}

reload_audio() {
    echo "Reloading ALSA ...."
    alsa force-reload
    echo "Reloading Pulse Audio ...."
    pulseaudio --kill && pulseaduio --start
}

get_active_conns() {
    lsof -i
}

sum_list() {
    local TOTAL
    for i in $(echo ${1})
    do
        TOTAL=$((${TOTAL} + ${i}))
    done
    echo ${TOTAL}
}

get_cpu_usage() {
    local CPU_STATS=$(cat /proc/stat | head -n1 | cut -f1 -d" " --complement)
    local CPU_STATS_WITH_IDLE=$(sum_list "${CPU_STATS}" )
    local CPU_STATS_NO_IDLE=$(sum_list "$(echo ${CPU_STATS} | cut -f4 -d" " --complement)")
    echo $(( (${CPU_STATS_NO_IDLE}) * 100 / (${CPU_STATS_WITH_IDLE})))
}

system_stat() {
    echo "################"
    echo "CPU USAGE: "$(get_cpu_usage)"%"
    echo "################"
    free -h
    echo "################"
    cat /etc/*release*
    echo "################"
    df -h
    echo "################"
    ip -4 address
    echo "################"
    ip -6 address
}

generate_gpg_key() {
    gpg --generate-key
}

get_gpg_public_key() {
    #Use email as the argument
    gpg --armor --export "${1}"
}

record_pulse_audio() {
    parecord -r -d ${1} --file-format=${2} ${3}
}

record_ffmpeg_audio() {
    ffmpeg -f pulse -i default ${1}
}

pulse_audio_info() {
    echo "################"
    pactl info
    echo "################"
    echo "Pulse Audio Sinks:"
    pacmd list-sinks
    echo "Pulse Audio Sources:"
    pacmd list-sources
    echo "Pulse Audio Cards:"
    pacmd list-cards
}

pulse_audio_help() {
    echo "Try pacmd, pactl, paplay, or parecord to interact and configure pulse audio streams/srevers/devices."
    echo "Use pulseaudio --kill and pulseaudio --start to restart the service."
    echo "For quality issues ensure the correct device profile is loaded."
}

alsa_audio_info() {
    echo "################"
    alsactl -v
    echo "################"
    echo "ALSA Audio Sinks:"
    aplay -l
    echo "ALSA Audio Sources:"
    arecord -l
    echo "All Devices:"
    aplay -L
}

alsa_audio_help() {
    echo "Try aslactl, aplay, or arecord to interact and configure pulse audio streams/srevers/devices."
    echo "Use alsa force-reload to restart the service."
    echo "Create/Update /etc/asound.conf to control pcm devices"
}

strip_begining_chars() {
    local VAL=${1}
    local LEN=$(echo ${VAL} | wc -c)
    local TO_REMOVE=${2}
    #LEN = 2 would imply a list of 1 element so we simply remove nothing and return
    if [[ "$(echo ${VAL} | head -c 1)" = "${TO_REMOVE}" && "${LEN}" != "2" ]]
    then
        echo "$(echo ${VAL} | rev | head -c $((${LEN} - 2)) | rev)"
    else
        echo "${VAL}"
    fi
}

#Take a deciaml value and the number of significant figures to keep EX. 10.12345 with an arg of 3 -> 10123
#this simply shifts the number as if we effectivley multiplied by a factor of 10, 100, 1000, etc ...
convert_dec_to_int() {
    local VAL=$(strip_begining_chars ${1} 0)
    local LOC=${2}
    local LEN=$(echo ${VAL} | wc -c)
    local INT_PART=$(echo ${VAL} | cut -f1 -d'.')
    echo "${INT_PART}$(echo ${VAL} | cut -f2 -d'.' | head -c ${LOC})"
}

#Takes a int value and the location to insert the decimal.
convert_int_to_dec() {
    local VAL=$(strip_begining_chars ${1} 0)
    local LOC=${2}
    local LEN=$(echo ${VAL} | wc -c)
    local DEC_PART=$(echo ${VAL} | rev | head -c ${LOC} | rev)
    echo "$(echo ${VAL} | head -c $((${LEN} - 1 - ${LOC}))).${DEC_PART}"
}

#This allows bash to add decimals by converting them to intergers. You should align your decimal values
#before using this function such that all arguments are the same length.
#Args: value1 to add, value2 to add.
add_dec() {
    local D_PLACES=$(($(echo ${1} | cut -f2 -d'.' | wc -c) - 1))
    local VAL1=$(convert_dec_to_int ${1} ${D_PLACES})
    local VAL2=$(convert_dec_to_int ${2} ${D_PLACES})
    local SUM=$((${VAL1} + ${VAL2}))
    echo "$(convert_int_to_dec ${SUM} ${D_PLACES})"
}

sub_dec() {
    add_dec ${1} -${2}
}

ffmpeg_split_audio_on_silence() {
    local LOCAL_RUN_STORE=$(date | md5sum | cut -f1 -d' ')
    touch ${LOCAL_RUN_STORE}
    ffmpeg -i "${1}" -af silencedetect=noise=-30dB:d=0.5 -f null - 2>> ${LOCAL_RUN_STORE}
    local START_OF_SILENCE=($(cat ${LOCAL_RUN_STORE} | grep silence_start | rev | cut -f1 -d' ' | rev | tr -s '\n' ' '))
    local END_OF_SILENCE=($(cat ${LOCAL_RUN_STORE} | grep silence_end | cut -f'2' -d':' | cut -f'1' -d'|'))
    local SILENCE_DURATON=($(cat ${LOCAL_RUN_STORE} | grep silence_duration | rev | cut -f1 -d' ' | rev | tr -s '\n' ' '))
    local INDEX=0
    for SOS in ${END_OF_SILENCE[@]}
    do
        if [[ "${SOS}" == "0" ]]
        then
            SOS="0.00"
        fi

        #Preincrement of INDEX as we will be using it to look ahead.
        INDEX=$((${INDEX} + 1))

        local SOS_RND="$(echo ${SOS} | cut -f1 -d'.').$(echo ${SOS} | cut -f2 -d '.' | rev | head -c 2 | rev)"
        local NEXT_SOS_RND="$(echo ${START_OF_SILENCE[${INDEX}]} | cut -f1 -d'.').$(echo ${START_OF_SILENCE[${INDEX}]} | cut -f2 -d '.' | rev | head -c 2 | rev)"
        local FILE_DURATION=$(sub_dec ${NEXT_SOS_RND} ${SOS_RND})
        echo "SOS_RND: ${SOS_RND}"
        echo "NEXT_SOS_RND: ${NEXT_SOS_RND}"
        echo "FILE_DURATION: ${FILE_DURATION}"
        if [[ "${START_OF_SILENCE[${INDEX}]}" == "" || "${START_OF_SILENCE[${INDEX}]}" == "." ]]
        then
            echo "Starting at ${SOS}"
            ffmpeg -ss ${SOS_RND} -i ${1} "split-${INDEX}-${1}"
        else
            echo "Starting at ${SOS_RND}, Ending at ${FILE_DURATION}"
            ffmpeg -ss ${SOS_RND} -t ${FILE_DURATION} -i ${1} "split-${INDEX}-${1}"
        fi

    done
    rm ./${LOCAL_RUN_STORE}
}
