#!/bin/bash

nr_host=5
if [ $# -lt 1 ]; then
  echo "Usage: $0 <arp trace file> [nr_host=$nr_host]"
  exit
fi
arp_trace=$1
if [ ! -e $arp_trace ]; then
  echo "$arp_trace not found"
  exit
fi
[ $# -ge 2 ] && nr_host=$2

result_fn=$PWD/arp.result
ip_prefix=192.168.0
mac_prefix=00:00:00:00:00
first_host_id=2
last_host_id=$(( $nr_host + 1 ))
master_ip=$ip_prefix.$first_host_id
master_mac=$mac_prefix:$(printf "%02x" $first_host_id)
root_dir=$PWD
master_dir=$root_dir/$master_ip

### clean all node directory
rm -rf $ip_prefix.*

### make master node and init w/ its own ip/mac as garp
mkdir -p $master_ip
pushd $master_ip
git init
echo $master_mac > $master_ip
git add $master_ip
git commit -m "master initial garp"
popd

master_merge() {
  pushd $master_dir
  ip=$1
  git merge $ip -m "Merge $ip"
  mac=$(cat $ip)
  popd

  ## emulate that the master checks its metadata that keeps which node has outdated entry
  for host_id in `seq $first_host_id $last_host_id`; do
    dst_ip=$ip_prefix.$host_id
    [ $dst_ip = $master_ip ] && continue
    dst_dir=$root_dir/$dst_ip
    pushd $dst_dir
    ## pull if ip's mac is not up-to-date
    if [ -e $ip ]; then
      if [ "$(cat $ip)" != $mac ]; then
        git pull
      fi
    fi
    popd
  done
}

### garp updates an entry on a local cache and push
### XXX: currently non-bare repo doesn't allow push
###      to master directly, so push to a different
###      branch named IP and merge it.
garp() {
  ip=$1
  mac=$2

  pushd $ip
  echo $mac > $ip
  git add $ip
  git commit -m "intial garp for $ip"
  if [ $ip != $master_ip ]; then
    git push origin master:$ip
    master_merge $ip
  fi
  popd
}

### initial fork from the master node
for host_id in `seq $first_host_id $last_host_id`; do
  ip=$ip_prefix.$host_id
  [ $ip = $master_ip ] && continue
  git clone $master_ip $ip
done

### initial garp reply at each one's local cache
for host_id in `seq $first_host_id $last_host_id`; do
  ip=$ip_prefix.$host_id
  [ $ip = $master_ip ] && continue
  mac=$mac_prefix:$(printf "%02x" $host_id)
  garp $ip $mac
done

### play trace
echo "## ARP result" > $result_fn
while read line; do
  cols=( $line )
  op=${cols[0]}

  if [ $op = "Q" ]; then
    ## ARP request
    src_ip=$ip_prefix.${cols[1]}
    dst_ip=$ip_prefix.${cols[2]}

    pushd $src_ip
    if [ -e $dst_ip ]; then
      ## cache hit
      dst_mac=$(cat $dst_ip)
    else
      ## cache miss
      git pull
      if [ -e $dst_ip ]; then
        dst_mac=$(cat $dst_ip)
      else
        dst_mac=""  # must NOT happen
      fi
    fi
    if [ "$dst_mac" != "" ]; then
      echo "ARP request from $src_ip: $dst_ip -> $dst_mac" >> $result_fn
    else
      echo "Error: ARP request from $src_ip for $dst_ip cannot be resolved" >> $result_fn
    fi
    popd
  elif [ $op = "G" ]; then
    ## GARP 
    src_ip=$ip_prefix.${cols[1]}
    src_mac=$mac_prefix:$(printf "%02x" ${cols[2]})
    garp $src_ip $src_mac
    echo "GARP from $src_ip -> $src_mac" >> $result_fn
  fi
done < $arp_trace

### dump each local cache and update log
for host_id in `seq $first_host_id $last_host_id`; do
  ip=$ip_prefix.$host_id
  pushd $ip

  echo -e "\n\n## $ip" >> $result_fn >> $result_fn
  ## dump local arp cache entries
  echo "[ARP cache]" >> $result_fn
  ips=( $(ls) )
  macs=( $(cat *) )
  nr_entry=${#ips[@]}
  for i in `seq 0 $(( $nr_entry - 1 ))`; do
    echo -e "${ips[i]}\t${macs[i]}" >> $result_fn
  done

  ## dump update log
  echo "[update log]" >> $result_fn
  git log --graph --abbrev-commit --format=format:'%h - %aD %d %s' --all >> $result_fn
  popd
done
