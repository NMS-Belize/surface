.. _installation:

Installing SURFACE CDMS
========================

S.U.R.F.A.C.E. CDMS SYSTEM REQUIREMENTS

Operating System: 
Ubuntu 20.04.5 (Focal Fossa)
https://releases.ubuntu.com/20.04.5

Main Memory: 4 GB (minimum requirement), 16GB
Disk storage: 25 GB (minimum requirement), 100GB
CPU cores: 4 (minimum requirement), 8

S.U.R.F.A.C.E. CDMS installation involves the following 10 steps

**Step 1 - Install Ubuntu 20.04.5 (Focal Fossa) on your machine(virtual or otherwise)**
-------------------------------------

**Step 2 - Install, Update and Upgrade basic packages**
-------------------------------------
$ sudo apt update
$ sudo apt upgrade

*ASIDE* - Virtual machine users may want to install openssh to enable easier. For example using putty to ssh into the machine to enable easier cut and paste of installation commands. Setup ssh by following the commands below:

sudo apt install openssh-server
sudo systemctl status ssh
ctrl + C 
sudo ufw allow ssh


**BACK TO SURFACE INSTALLATION**

**STEP 3 - Install important pre-requisities**
------------------------------------
$ sudo apt install build-essential gcc make perl dkms curl
$ sudo apt install git


FYI - Documentation on Prerequisites needed for installation steps are linked below 

Docker:
https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-20-04
Docker-Compose:
https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-compose-on-ubuntu-20-04

PostgreSQL:(NOT NEEDED)
https://www.digitalocean.com/community/tutorials/how-to-install-postgresql-on-ubuntu-20-04-quickstart


**Step 4 - Docker Installation**
-------------------------
# Update and Prerequisite Packages:
$ sudo apt update
$ sudo apt install apt-transport-https ca-certificates curl software-properties-common

#. Add the GPG key for the official Docker repository
$ curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

# Add the Docker repository to APT sources:
$ sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable"

# Make sure you are about to install from the Docker repo instead of the default Ubuntu repo:
$ apt-cache policy docker-ce

# Install Docker
$ sudo apt install docker-ce
$ sudo systemctl status docker
ctrl+c

# Setting docker to run without sudo:
$ sudo usermod -aG docker ${USER}
$ su - ${USER}
$ groups

PLEASE NOTE - for some reason during our first installation process we had to run the last three commands repeatedly to make sure that “docker” was a user within “groups”. When you run the “groups” command if “docker” is not listed some of the following installation steps failed so we had to run these commands again to ensure that “docker” was displayed under “groups”. I do not know why this was happening. We have not encountered that issue again when installing but just made a note of it.

(VM) Restart your Virtual Machine(If you are running a VM) - not sure if this is necessary

**Step 5 - Docker-Compose Installation**
----------------------------
Download the 1.29.2 release and save the executable file at ‘/usr/local/bin/docker-compose’:
$ sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose

Setting Permissions for docker-compose
$ sudo chmod +x /usr/local/bin/docker-compose

Verifying Installation:
$ docker-compose --version


**Step 6 - Download repository and production file** 
---------------------------------------------------
Download the source code from GitHub repository
$ git clone https://github.com/opencdms/surface

Configure environment variables in ‘surface/api/production.env’ file. For security purposes the production.env file needed to build the environment is not found in the repository. The repository contains a sample file that will need to be replaced. We need to go into the surface/api directory and delete the dummy production file and replace it with the real file. The file needed for installation is provided on the FTP server below.

Remove dummy file

cd surface/api
sudo rm -rf production.example.env

Get real file

ftp db.hydromet.gov.bz 5394
Username: surfacefiles
Password: surf@c3f!l3s

get production.env
ls (to check if the file is in the api directory)
cd .. (exit api directory)

**STEP 7 - Build Docker images**
----------------------------------
Build Docker Images
$ docker-compose build

(NOTE -  The build command should be run from the “/surface” directory (you may currently be in the surface/api directory after setting up the production.env file, therefore you need to “cd ..” to exit “/surface/api”)


Start Docker with ONLY these 4 containers

$ docker-compose up postgres cache redis api


NOTE  - We need to exit docker up without killing the 4 containers we just brought up. To do so use the command “Ctrl + \” and you should see the command prompt again.


To install SURFACE Without Data:
$ docker-compose exec api bash load_initial_data.sh

To install With backup data dump file:
$ docker-compose exec -T postgres psql -U dba -d surface_db < backup_data.sql


**STEP 8 - Initial setup to Postgres database**
---------------
Collect Static Files and Create User:
$ docker-compose exec api python manage.py collectstatic --noinput

$ docker-compose exec api python manage.py createsuperuser


**STEP 9 - Starting SURFACE**
-------------
Stop Docker:
$ docker-compose stop (CTRL+C)

Start Docker
$ docker-compose up
(background start) $ docker-compose up -d

**Step 10 - Open browser and login to application**
----------------
Open in Browser(if you are viewing from the same machine)
0.0.0.0:8080

Or use the private IP of the machine running the application

Installation notes


VirtualBox Machine:
VirtualBox  7.0.2 (Windows hosts)
https://www.virtualbox.org/wiki/Downloads
Initial Setup/Updates - minimal machine specifications(for testing not production)
System Information:(if using a VM you can use these specs)

