#!/bin/bash
#Automating dry-run upgrade steps by Alex Silkin
#6/13/24

set -eu
#Help utility

LOCK_FILE=/tmp/dry-run.lock
LOG=/tmp/dry-run.log
PRE_FLIGHT_LOG=/tmp/lw-preflight-checks.log
EL8_PACKAGES=/tmp/el8_packages.log


print_usage()
{
echo "This script is used to automate and accelerate the staging dry-run process"
echo "Syntax: dry-run.sh [-s|--stage -h|--help]"
echo "Options:"
echo "-s|--stage        Re-run a specific stage of the dry-run script"
echo "-h|--help         Print this help message"
echo "-p|--packages     Calculate el7/el8 packages"
}

stage_0()
{
touch $PRE_FLIGHT_LOG
touch $LOCK_FILE
touch $LOG
touch $EL8_PACKAGES

if [[ ! -s ${LOCK_FILE} ]]
then
  echo "Starting a new dry-run test at $(date)"  2>&1 | tee -a $LOG
  echo "$(date) Upgrade paths, lock-file, and log-file have been setup"  2>&1 | tee -a $LOG
  echo "Proceeding with Stage 1"  2>&1 | tee -a $LOG 
  echo "Stage 0 completed" > $LOCK_FILE
else
  case $(cat $LOCK_FILE) in
  "Stage 0 completed")
  echo "Please proceed with Stage 1"
  ;;
  "Stage 1 completed")
  echo "Upgrade in progress, please proceed with Stage 2"
  ;;
  "Stage 2 completed")
  echo "Upgrade in progress, please proceed with Stage 3 (pre-flight checks)"
  ;;
  "Stage 3 completed")
  echo "Please fix pre-flight checks and proceed with Stage 4"
  ;;
  "Stage 4 completed")
  echo "elevate-cpanel is in progress please proceed with Stage 5 once it is finished"
  ;;
  esac
fi
}

stage_1()
{
#Disable Exim
    echo -e "Disabling Exim...\n" | tee -a $LOG
    whmapi1 configureservice service=exim enabled=0 monitored=0 | tee -a $LOG 
    echo "Exim Disabled" | tee -a $LOG

#Re-create /boot/grub2/grub.cfg
    echo -e "Rebuilding /boot/grub2/grub.cfg\n" | tee -a $LOG
    grub2-mkconfig -o /boot/grub2/grub.cfg | tee -a $LOG

#Re-install kernel files
    yum -y reinstall kernel kernel-devel kernel-headers kernel-tools kernel-tools-libs | tee -a $LOG

#Mask plymouth-reboot service
    systemctl mask plymouth-reboot.service | tee -a $LOG; systemctl daemon-reload | tee -a $LOG
    echo "Stage 1 completed" >> /etc/motd
    echo "Stage 1 completed" > $LOCK_FILE
    reboot
}


stage_2()
{
    echo -e "Adding default MariaDB/MySQL MySQL db data and restarting the service...\n" | tee -a $LOG
#Check whether system is using MariaDB or MySQL, then setup default MySQL table accordingly
    if [[ $(mysql -V | grep "MariaDB") ]];
     then
        echo "This server uses MariaDB" | tee -a $LOG
        mariadb_pid="$(systemctl status mysqld | grep "Main PID:" | awk '{print $3}')"; kill -9 "$mariadb_pid";
        mysql_install_db --user=mysql;
     else
        echo "This server uses MySQL" | tee -a $LOG
        echo -e '[mysqld]\nskip-grant-tables\n' > /etc/my.cnf;
        mkdir /var/lib/mysql-files;
        chown mysql: /var/lib/mysql-files;
        chmod 750 /var/lib/mysql-files;
        echo -e "Restarting MariaDB/MySQL...\n" | tee -a $LOG
     fi
     
     systemctl restart mysqld || systemctl restart mariadb

    echo -e "Disabling LW-provided repos...\n" | tee -a $LOG
    for repo in stable-{arch,generic,noarch} system-{base,extras,updates,updates-released};
    do
      yum-config-manager --disable "$repo" | grep -E 'repo:|enabled' | tee -a $LOG;
    done
#Removing LW-provided centos-release
    echo -e "Removing LW-provided centos-release...\n" | tee -a $LOG
    rpm -e --nodeps centos-release
#Installing CentOS7-provided centos-release and updating packages
    yum -y install http://mirror.centos.org/centos/7/os/x86_64/Packages/centos-release-7-9.2009.0.el7.centos.x86_64.rpm | tee -a $LOG
    yum update -y | tee -a $LOG
    sleep 5
#Getting ready for pre-flight checks
    echo "Stage 2 completed" > $LOCK_FILE
    echo "Stage 2 completed, moving on to pre-flight checks" >> /etc/motd
    reboot
} 

stage_3()
{
#Running the LW upgrade pre-flight checks
     echo -e "Downloading and running LW and cPanel pre-flight checks:\n" | tee -a $LOG
     bash <(curl -s https://files.liquidweb.com/support/elevate-scripts/elevate_preflight.sh) | tee -a $LOG
#Downloading elevate-cpanel
     wget -O /scripts/elevate-cpanel https://raw.githubusercontent.com/cpanel/elevate/release/elevate-cpanel; chmod 700 /scripts/elevate-cpanel
     echo -e "Disabling /var/cpanel/elevate-noc-recommendations" | tee -a $LOG
#Disabling /var/cpanel/elevate-noc-recommendations 
     mv /var/cpanel/elevate-noc-recommendations{,.disabled}
#Running cPanel preflight-checks: 
     echo -e "Running cPanel Pre-flight check...\n" | tee -a $LOG
    /scripts/elevate-cpanel --check | tee -a $LOG
     echo -e "\nPlease manualy address the upgrade blockers" | tee -a $LOG
     echo "Stage 3 completed" > $LOCK_FILE
}

stage_4()
{

bash <(curl -s https://files.liquidweb.com/support/elevate-scripts/install_post_leapp.sh)
/scripts/elevate-cpanel --start --non-interactive --no-leapp

}

#Stage5 waits while '/scripts/elevate-cpanel --start --non-interactive -no-leapp' runs
stage_5()
{
#Setting up Alma8 elevate repo + leapp upgrades packages
echo "cPanel elevate script completed successfully:" 
echo "Installing AlmaLinux8 elevate repo:"
yum install -y https://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm
echo "Installing leapp-upgrade and leapp-data-almalinux"
yum install -y leapp-upgrade leapp-data-almalinux

#Setting up Leapp Answer file and logs
echo "Setting up /var/log/leaap and Leapp Answerfile"
mkdir -pv /var/log/leapp
touch /var/log/leapp/answerfile
echo '[remove_pam_pkcs11_module_check]' >> /var/log/leapp/answerfile
leapp answer --section remove_pam_pkcs11_module_check.confirm=True

#Removing kernel-devel packages
rpm -q kernel-devel &>/dev/null && rpm -q kernel-devel | xargs rpm -e --nodeps

#Setting LEAPP_OVL_SIZE=3000 and running Leapp upgrade.
echo "Setting LEAPP_OVL_SIZE=3000"
export LEAPP_OVL_SIZE=3000
echo "Beginning LEAPP Upgrade":
leapp upgrade --reboot
}
 
count_el8_packages()
{
#Counting EL7/EL8 packages
  rpm -qa | grep -v cpanel | grep -Po 'el[78]' \
  | sort | uniq -c | sort -rn;echo;rpm -qa | grep -v cpanel \
  | grep 'el7' | sort | uniq | sort -rn | nl > $EL8_PACKAGES >&1
}

#Check whether any options were passed to the script
while getopts ":hps:-:" opt; do
  case $opt in
    h)
      print_usage
      exit;;
    p)
      echo "Counting el7/el8 packages"
      count_el8_packages
      ;;
    s) #Select a specific stage of the script
        case "${OPTARG}" in
            1)
              echo "Executing Stage 1"
              stage_1
              ;;
            2)
              echo "Executing Stage 2"
              stage_2
              ;;
            3)
              echo "Executing Stage 3 (Pre-flight checks)" 
              stage_3
              ;;
            4)
              echo "Executing Stage 4 (/scripts/elevate-cpanel --start --non-interactive --no-leapp)"
              stage_4
              ;;
            5)
              echo "Executing Stage 5 (Leapp Setup and Leapp Upgrade)"
              stage_5
              ;;
            *)
              echo "Error: Invalid option: --$OPTARG"
              exit;;
        esac;;
    -)
        case "${OPTARG}" in
            help)
                print_usage
                ;;
            stage)
                echo "Stage"
                case "${OPTARG}" in
                    1)
                    echo stage1
                    ;;
                    2)
                    echo stage2
                    ;;
                    3)
                    echo stage3
                    ;;
                    *)
                    echo "Error: Invalid option: --$OPTARG"
                    ;;
                esac
                ;;

        *)
          echo "Error: Invalid option: --$OPTARG"
          exit 1
          ;;
    esac;;
    \?)
      echo "Invalid option: -$OPTARG"
      exit 1
      ;;
  esac
done

stage_0
# echo -e "\nDry-run automatic steps have completed. Please manualy address the upgrade blockers" >> /etc/motd
# cat /etc/motd