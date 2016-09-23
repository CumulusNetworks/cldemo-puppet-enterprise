
Before you start
----------------
If you don't already have a license for Puppet Enterprise, you can get a trial license
for deployments up to 10 devices for free by visiting
[https://puppet.com/download-puppet-enterprise](https://puppet.com/download-puppet-enterprise).
Copy the download URL for the Puppet Enterprise Master for Ubuntu 16.04.


Installing Puppet Enterprise
----------------------------
The reference topology by default only gives 1G of RAM to the `oob-mgmt-server`.
You will need to increase the RAM for the `oob-mgmt-server` to 2G in order for
Puppet Enterprise to install.

    git clone https://github.com/cumulusnetworks/cldemo-vagrant
    cd cldemo-vagrant
    # edit Vagrantfile and replace v.memory for the oob-mgmt-server from 1024 to 2048
    sed -i 's/v.memory = 1048/v.memory = 2048/g' Vagrantfile
    vagrant up oob-mgmt-server oob-mgmt-switch leaf01 leaf02 spine01 spine02 server01 server02
    vagrant ssh oob-mgmt-server
    sudo su - cumulus
    wget 'https://pm.puppetlabs.com/cgi-bin/download.cgi?dist=ubuntu&rel=16.04&arch=amd64&ver=latest' -O puppet-enterprise.tar.gz
    wget -O - https://downloads.puppetlabs.com/puppetlabs-gpg-signing-key.pub | gpg --import
    tar xvf puppet-enterprise.tar.gz
    cd puppet-enterprise-*
    sudo ./puppet-enterprise-installer
    # press enter to install the webserver

*In a new terminal*

    ssh -L 9000:localhost:3000 vagrant@localhost -p 2222 -o StrictHostKeyChecking=no
    vagrant

Leave this terminal open for the duration of the demo - this creates an SSH
tunnel that will allow you to use the Puppet website from your host machine.
In Firefox or Chrome, navigate to [https://127.0.0.1:9000](https://127.0.0.1:9000).
You will receive an error message stating that your connection is not secure.
Go to Advanced and either add an exception or tell it to proceed to localhost
anyway.

 * Choose Monolithic Install.
 * Set the FQDN to oob-mgmt-server.lab.local
 * Set the admin password to `CumulusLinux!`

![](fig1.png)

![](fig2.png)

![](fig3.png)

Don't worry about the validation warnings. Just click on Deploy Now.
