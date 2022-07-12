#!/bin/bash

source setup/functions.sh

echo "Installing Mail-in-a-Box system management daemon..."

# DEPENDENCIES

# We used to install management daemon-related Python packages
# directly to /usr/local/lib. We moved to a virtualenv because
# these packages might conflict with apt-installed packages.
# We may have a lingering version of acme that conflcits with
# certbot, which we're about to install below, so remove it
# first. Once acme is installed by an apt package, this might
# break the package version and `apt-get install --reinstall python3-acme`
# might be needed in that case.
while [ -d /usr/local/lib/python3.4/dist-packages/acme ]; do
	pip3 uninstall -y acme;
done

# duplicity is used to make backups of user data.
#
# virtualenv is used to isolate the Python 3 packages we
# install via pip from the system-installed packages.
#
# certbot installs EFF's certbot which we use to
# provision free TLS certificates.
apt_install duplicity python3-pip python3-gpg virtualenv certbot rsync

# boto is used for amazon aws backups.
# Both are installed outside the pipenv, so they can be used by duplicity
hide_output pip3 install --upgrade boto

# Create a virtualenv for the installation of Python 3 packages
# used by the management daemon.
inst_dir=/usr/local/lib/mailinabox
mkdir -p $inst_dir
venv=$inst_dir/env
if [ ! -d $venv ]; then
	hide_output virtualenv -ppython3 $venv
elif [ ! -f $venv/.oscode ]; then
	echo "Re-creating Python environment..."
	rm -rf $venv
	hide_output virtualenv -ppython3 $venv
elif [ "$(cat $venv/.oscode)" != $(get_os_code) ]; then
	echo "Existing management environment is from an earlier version of the OS you're running."
	echo "Re-creating Python environment..."
	rm -rf $venv
	hide_output virtualenv -ppython3 $venv
fi

# Upgrade pip because the Ubuntu-packaged version is out of date.
hide_output $venv/bin/pip install --upgrade pip

# Install other Python 3 packages used by the management daemon.
# The first line is the packages that Josh maintains himself!
# NOTE: email_validator is repeated in setup/questions.sh, so please keep the versions synced.
hide_output $venv/bin/pip install --upgrade \
	rtyaml "email_validator>=1.0.0" "exclusiveprocess" \
	flask dnspython python-dateutil expiringdict \
	qrcode[pil] pyotp \
	"idna>=2.0.0" "cryptography==2.2.2" boto psutil postfix-mta-sts-resolver

# Install backblaze B2 libraries.
# Depending on the OS, Duplicity may require different dependencies.
case $(get_os_code) in

	$OS_DEBIAN_10)
		apt_install python-pip python-backports.functools-lru-cache
		hide_output pip2 install --upgrade "b2<2.0.0" "logfury<1.0.0"
		hide_output $venv/bin/pip install --upgrade "b2<2.0.0"
		;;

	$OS_UBUNTU_2004 | $OS_DEBIAN_11)
		hide_output pip3 install --upgrade "b2sdk==1.7.0"
		hide_output $venv/bin/pip install --upgrade "b2sdk==1.7.0"
		;;

esac

# Make the venv use the packaged gpgme bindings (the ones pip provides are severely out-of-date)
if [ ! -d $venv/lib/python$(python_version)/site-packages/gpg/ ]; then
	ln -s /usr/lib/python3/dist-packages/gpg/ $venv/lib/python$(python_version)/site-packages/
fi

echo $(get_os_code) > $venv/.oscode

# CONFIGURATION

# Create a backup directory and a random key for encrypting backups.
mkdir -p $STORAGE_ROOT/backup
if [ ! -f $STORAGE_ROOT/backup/secret_key.txt ]; then
	$(umask 077; openssl rand -base64 2048 > $STORAGE_ROOT/backup/secret_key.txt)
fi


# Download jQuery and Bootstrap local files

# Make sure we have the directory to save to.
assets_dir=$inst_dir/vendor/assets
rm -rf $assets_dir
mkdir -p $assets_dir

# jQuery CDN URL
jquery_version=3.6.0
jquery_url=https://code.jquery.com

# Get jQuery
wget_verify $jquery_url/jquery-$jquery_version.min.js b82d238d4e31fdf618bae8ac11a6c812c03dd0d4 $assets_dir/jquery.min.js

# Bootstrap CDN URL
bootstrap_version=5.1.3
bootstrap_url=https://github.com/twbs/bootstrap/releases/download/v$bootstrap_version/bootstrap-$bootstrap_version-dist.zip

# Get Bootstrap
wget_verify $bootstrap_url 2b56a45f7108051642bfc446947fc1d626cb1c9f /tmp/bootstrap.zip
unzip -q /tmp/bootstrap.zip -d $assets_dir
mv $assets_dir/bootstrap-$bootstrap_version-dist $assets_dir/bootstrap
rm -f /tmp/bootstrap.zip

# FontAwesome CDN URL
fontawesome_version=6.1.1
fontawesome_url=https://github.com/FortAwesome/Font-Awesome/releases/download/$fontawesome_version/fontawesome-free-$fontawesome_version-web.zip

# Get FontAwesome
wget_verify $fontawesome_url d712b10472f7209d5284f394ef94a7be71fc2ad3 /tmp/fontawesome.zip
unzip -q /tmp/fontawesome.zip -d $assets_dir
mv $assets_dir/fontawesome-free-$fontawesome_version-web $assets_dir/fontawesome
rm -f /tmp/fontawesome.zip

# Create an init script to start the management daemon and keep it
# running after a reboot.
cat > $inst_dir/start <<EOF;
#!/bin/bash
# Set character encoding flags to ensure that any non-ASCII don't cause problems.
export LANGUAGE=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_TYPE=en_US.UTF-8

source $venv/bin/activate
exec python $(pwd)/management/daemon.py
EOF
chmod +x $inst_dir/start
cp --remove-destination conf/mailinabox.service /lib/systemd/system/mailinabox.service # target was previously a symlink so remove it first
hide_output systemctl link -f /lib/systemd/system/mailinabox.service
hide_output systemctl daemon-reload
hide_output systemctl enable mailinabox.service

# Perform nightly tasks at 3am in system time: take a backup, run
# status checks and email the administrator any changes.

minute=$((RANDOM % 60))  # avoid overloading mailinabox.email
cat > /etc/cron.d/mailinabox-nightly << EOF;
# Mail-in-a-Box --- Do not edit / will be overwritten on update.
# Run nightly tasks: backup, status checks.
$minute 3 * * *	root	(cd $(pwd) && management/daily_tasks.sh)
EOF

# Start the management server.
restart_service mailinabox

# FOR DEVELOPMENT PURPOSES ONLY:
# If there is a CA certificate in the folder, install it.
# MIAB will only accept a manual certificate installation
# if it is signed by a CA trusted by it.
if [[ -f mailinabox-ca.crt ]]; then
    echo "Custom CA certificate detected. Installing..."
    rm -f /usr/local/share/ca-certificates/mailinabox-ca.crt
    cp mailinabox-ca.crt /usr/local/share/ca-certificates/
    hide_output update-ca-certificates --fresh
fi
