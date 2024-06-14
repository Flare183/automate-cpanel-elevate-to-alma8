#!/bin/bash
#Automating dry-run upgrade steps by Alex Silkin
#6/13/24

mkdir /home/temp
touch /home/temp/dry-run.log
LOG=/home/temp/dry-run.log
touch /home/temp/dry-run.lock
LOCK_FILE=/home/temp/dry-run.lock

#Help utility
print_usage()
{
echo "This script is used to automate and accelerate the staging dry-run process"
echo "Syntax: dry-run.sh [-s|--stage -h|--help]"
echo "Options:"
echo "-s|--stage        Re-run a specific stage of the dry-run script"
echo "-h|--help         Print this help message"     
}

stage_0()
{

 echo "Starting a new dry-run test"
 echo "Stage 0" > $LOCK_FILE
  echo "Dry-run test is in progress, processing $(cat $LOCK_FILE)" | tee -a $LOG
 
      echo "Setting up cron job to run dry-run.sh after reboot" | tee -a $LOG
      echo "@reboot /bin/bash /root/dry-run.sh" >> /var/spool/cron/root
      echo "Stage 1" > $LOCK_FILE
      stage1
}

stage1()
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
    echo "Stage 2" > $LOCK_FILE
    reboot
}


stage2()
{
    echo -e "Adding default MariaDB/MySQL MySQL db data and restarting the service...\n" | tee -a $LOG
#Check for whether system is using MariaDB or MySQL, then setup default MySQL table accordingly
    if [[ $(mysql -V | grep "MariaDB") ]];
     then
        echo "This server uses MariaDB"
        mariadb_pid="$(systemctl status mysqld | grep "Main PID:" | awk '{print $3}')"; kill -9 "$mariadb_pid";
        mysql_install_db --user=mysql;
     else
        echo "This server uses MySQL"
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
    
    echo -e "Removing LW-provided centos-release...\n" | tee -a $LOG
    rpm -e --nodeps centos-release | tee -a $LOG
    echo "Stage 2 completed" >> /etc/motd
    #Getting ready for stage 3
    echo "Stage 3" > $LOCK_FILE

    yum -y install http://mirror.centos.org/centos/7/os/x86_64/Packages/centos-release-7-9.2009.0.el7.centos.x86_64.rpm | tee -a $LOG; yum update -y | tee -a $LOG && sleep 5 && echo "Yum updates completed, moving on to pre-flight checks" >> /etc/motd && reboot
} 

stage3()
{
     echo -e "Downloading and running LW and cPanel pre-flight checks:\n" | tee -a $LOG
     bash <(curl -s https://files.liquidweb.com/support/elevate-scripts/elevate_preflight.sh) | tee -a $LOG
     wget -O /scripts/elevate-cpanel https://raw.githubusercontent.com/cpanel/elevate/release/elevate-cpanel; chmod 700 /scripts/elevate-cpanel
     echo -e "Disabling /var/cpanel/elevate-noc-recommendations" | tee -a $LOG
     mv /var/cpanel/elevate-noc-recommendations{,.disabled}
     
     echo -e "Running cPanel Pre-flight check...\n" | tee -a $LOG
    /scripts/elevate-cpanel --check | tee -a $LOG
     echo -e "\nPlease manualy address the upgrade blockers" | tee -a $LOG
     echo "Stage 4" > $LOCK_FILE

}

stage4()
{

bash <(curl -s https://files.liquidweb.com/support/elevate-scripts/install_post_leapp.sh)
/scripts/elevate-cpanel --start --non-interactive --no-leapp

}

#Stage5 waits while '/scripts/elevate-cpanel --start --non-interactive -no-leapp' runs
stage5()
{
ELEVATE_PROGRESS="running"
  until [ "${ELEVATE_PROGRESS}" == "done" ]
  do
     if [ "$(grep "You should upgrade this distribution manually." /tmp/elevate.log)" ] && [ "$(grep "The cPanel elevation process is currently paused" /tmp/elevate.log)" ];
     then
     echo "Elevate is done"
       ELEVATE_PROGRESS="done"
    fi
  done;

 # && \
 #    "$(grep "The cPanel elevation process is currently paused" /tmp/elevate.log)" 

echo "cPanel elevate script completed successfully:" 

echo "Installing AlmaLinux8 elevate repo:"

yum install -y https://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm

echo "Installing leapp-upgrade and leapp-data-almalinux"

yum install -y leapp-upgrade leapp-data-almalinux

echo "Setting up /var/log/leaap and Leapp Answerfile"

mkdir -pv /var/log/leapp
touch /var/log/leapp/answerfile
echo '[remove_pam_pkcs11_module_check]' >> /var/log/leapp/answerfile
leapp answer --section remove_pam_pkcs11_module_check.confirm=True
rpm -q kernel-devel &>/dev/null && rpm -q kernel-devel | xargs rpm -e --nodeps

echo "Setting LEAPP_OVL_SIZE=3000"
export LEAPP_OVL_SIZE=3000

echo "Beginning LEAPP Upgrade":

leapp upgrade --reboot

}

#Check whether any options were passed to the script
while getopts ":hs:-:" opt; do
  case $opt in
    h)
      print_usage
      exit;;
    s) #Select a specific stage of the script
        case "${OPTARG}" in
            1)
              echo Executing stage1
              stage1
              ;;
            2)
              echo Executing stage2
              stage2
              ;;
            3)
              echo Executing stage3
              stage3
              ;;
            4)
              echo Executing stage4
              stage4
              ;;
            5)
              echo Executing stage5
              stage5
              ;;
            *)
              echo "Error: Invalid option: --$OPTARG"
              exit;;
        esac;;
    -)
        case "${OPTARG}" in
            help)
                print_usage
                exit;;
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
                esac;;

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

# echo -e "\nDry-run automatic steps have completed. Please manualy address the upgrade blockers" >> /etc/motd
# cat /etc/motd