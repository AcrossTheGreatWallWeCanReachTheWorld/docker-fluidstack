#!/bin/bash

test_program_installed () {
    if command -v $1 > /dev/null; then
        echo "Program $1 successfully installed"
    else
        echo "Program $1 not installed"
        exit 1
    fi
}

install_docker() {
    curl -Lo /usr/local/bin/udocker.py2 https://github.com/indigo-dc/udocker/raw/master/udocker.py
    echo '#!/bin/sh' > /usr/local/bin/docker
    echo 'exec python2 /usr/local/bin/udocker.py2 --allow-root "$@"' >> /usr/local/bin/docker
    chmod +x /usr/local/bin/docker
    docker install
}

make_config () {
  token="$1"
  ports="$2"

  file="$fluidstack_home/.fs_config.yaml"

  echo "################################################################################" > $file
  echo "# FluidStack node config file in yaml format                                   #" >> $file
  echo "################################################################################" >> $file
  echo "" >> $file
  echo "################################################################################" >> $file
  echo "# clusterToken                                                                 #" >> $file
  echo "# A token unique to a provider that can be found on the provider dashboard     #" >> $file
  echo "# https://provider.fluidstack.io/dashboard                                     #" >> $file
  echo "################################################################################" >> $file
  echo "# clusterToken: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" >> $file

  echo "" >> $file
  echo "clusterToken: ${token}" >> $file
  echo "" >> $file

  echo "################################################################################" >> $file
  echo "# ports                                                                        #" >> $file
  echo "# A list of port forwards from the router to an internal port in format        #" >> $file
  echo "# 'local: external'  Can be left empty if UPnP is enabled on the router.       #" >> $file
  echo "################################################################################" >> $file
  echo "# ports:" >> $file
  echo "#   1000: 2000" >> $file
  echo "#   1001: 2001" >> $file

  echo "" >> $file
  echo -n "ports:" >> $file

  IFS=',' read -ra MAPPINGS <<< "$ports"
  for mapping in "${MAPPINGS[@]}"; do
    p1=""
    p2=""

    IFS=':' read -ra PORTS <<< "$mapping"
    for port in "${PORTS[@]}"; do
      if [[ "$p1" -eq "" ]]; then
        p1="$port"
      else
        p2="$port"
      fi
    done

    printf "\n  %s: %s" "$p1" "$p2" >> "$file"
  done

  echo "" >> $file
}

prompt_cluster_token() {
  loop="true"

  while $loop -eq "true"; do
    read -p "Enter your cluster token: " -r </dev/tty

    IFS='-' read -ra TOKEN_PARTS <<< "$REPLY" # split string by dash
    c=0 # parts in string, expect 4

    for _ in "${TOKEN_PARTS[@]}"; do
      c=$((c + 1))
    done

    if [[ $c != "5" ]]; then
      echo "Bad token, please try again (e.g. '12358f2d9-5d6g-4b3b-a7c3-cc1233dcb123')"
    else
      loop="false"
    fi
  done

  cluster_token="$REPLY"
}

prompt_ports() {
  loop="true"
    
  while $loop -eq "true"; do
    read -p "Enter port mappings as local:external, separated by a comma eg: (3000:4000). You can leave empty if UPnP is allowed on router: " -r </dev/tty

    IFS=',' read -ra PORT_MAPPINGS <<< "$REPLY" # split string by comma
    c=0 # parts in string
    bad_mapping="false"

    [[ $REPLY == '' ]] && return

    for i in "${PORT_MAPPINGS[@]}"; do
      c=$((c + 1))

      # check port mapping contains colon
      if [[ ${i} != *":"* ]]; then
        bad_mapping="$PORT_PARTS"
      fi

      # check it has two ports either side of colon
      IFS=':' read -ra PORT_PARTS <<< "$i" # split string by colon
      pc=0 # parts in port mapping, expect 2

      for p in "${PORT_PARTS[@]}"; do
        pc=$((pc + 1))
      done

      if [[ $pc -ne "2" ]]; then
        bad_mapping="$PORT_PARTS"
        break
      else
        bad_mapping="false"
      fi
    done

    if [[ "$bad_mapping" -ne "false" ]]; then
      echo "Bad port mapping: \"$bad_mapping\""
    elif [[ $c -lt "5" ]]; then
      echo "Expecting at least 5 ports mapping (e.g. \"4000:5000\")"
    else
      loop="false"
    fi
  done

  ports="$REPLY"
}

fluidstack_home="/usr/local/fluidstack"
fluidstack_lib="$fluidstack_home/lib"
fluidstack_bin="$fluidstack_home/bin"
fluidstack_nomad_dir="$fluidstack_home/nomad"

if [ ! -d "$fluidstack_home" ]; then
    echo "Creating new home directory"
    mkdir -p $fluidstack_home/{lib,bin,tmp}
fi

fluidstack_user="root"
fluidstack_group="root"

# Install Docker
install_docker

# Set variables
node_version="v0.6.5"
archive_folder="$fluidstack_lib/$node_version"
archive_name=$node_version"_linux.tar.gz"
archive="$fluidstack_lib/$archive_name"
exec="fluidnode"
unit_file="fluidstack.service"
release_bucket="fluidstack-releases"
release_uri="https://$release_bucket.s3.eu-west-2.amazonaws.com/$archive_name"

curl -fL# -o "$archive" "$release_uri"
[ -d "$archive_folder" ] || mkdir $archive_folder
tar -C $archive_folder -zxf $archive && rm $archive

rm "$fluidstack_bin/$exec"
ln -s "$archive_folder/$exec" "$fluidstack_bin/$exec"

# Change owner of whole dir
chown $fluidstack_user:$fluidstack_group "$fluidstack_bin/$exec"

test_program_installed "$fluidstack_bin/$exec"

# Install and test ffmpeg binaries
cp "$archive_folder/ffmpeg" /usr/local/bin
chown $fluidstack_user:$fluidstack_group /usr/local/bin/ffmpeg
chmod +x /usr/local/bin/ffmpeg
test_program_installed "ffmpeg"

echo chmod +x "$archive_folder/$exec"
chmod +x "$archive_folder/$exec"
chown -R $fluidstack_user:$fluidstack_group "$fluidstack_home"

prompt_cluster_token # sets ret value on $cluster_token
prompt_ports # sets ret value on $ports
make_config "$cluster_token" "$ports"

# Install and test nomad binary
cp "$archive_folder/nomad" $fluidstack_bin
chown $fluidstack_user:$fluidstack_group "$fluidstack_bin/nomad"
chmod +x "$fluidstack_bin/nomad"
test_program_installed "$fluidstack_bin/nomad"

# Setup nomad dirs
mkdir -p "$fluidstack_nomad_dir/certs"
mkdir -p "$fluidstack_nomad_dir/conf"
mkdir -p "$fluidstack_nomad_dir/data"

# Move Nomad config
cp "$archive_folder/client.hcl" "$fluidstack_nomad_dir/conf"

mkdir /usr/local/fluidstack/tmp
cd /usr/local/fluidstack/tmp
mkdir -p /var/log/fluidstack
touch /var/log/fluidstack/file.log
until /usr/local/fluidstack/bin/fluidnode
do
  :
done
