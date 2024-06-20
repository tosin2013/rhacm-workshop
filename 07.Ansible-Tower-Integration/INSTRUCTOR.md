# Instructor Guide

This section seeks to help an instructor setup an Ansible Automation Platform environment to provide the workshop participants to use.

## Prerequisites
* Install an Ansible Automation Platform instance on an external VM (Red Hat employees can use RHPDS).

## Preperations for exercise 1 (Integration with Applications Lifecycle) -
1. Log into the Ansible Automation Platform web interface and create an Ansible Automation Platform application at _Administration_ -> _Applications_.
2. Create token for admin user for application at _Users_-> _admin_ -> _Tokens_ -> _Add_. Select the created application and the _Write_ scope. Copy the token to a local machine.
3. In order to host the participants log files, on the Ansible Automation Platform server, install an httpd server by running the next command - `export KUBECONFIG=/home/cloud-user/cluster/auth/kubeconfig`.
4. Deploy the httpd server by running the next command - `oc apply -k httpd-server/overlays/default`.
5. In the Ansible Automation Platform web interface, create a project, and point it to the workshop's git repository (https://github.com/tosin2013/rhacm-workshop.git).
6.  Create Ansible Automation Platform job template, name it Logger, make sure to allow `prompt vars` and `promt inventories` by ticking the boxes next to the instances. Associate the job template with the `07.Ansible-Tower-Integration/ansible-playbooks/logger-playbook.yml` playbook. Associate the job template with the created inventory and credentials.
7.  Provide the participants with the token you created in `step 2` alongside the web URL for the Ansible Automation Platform web server. Also, provide participants with a user / password to login into the web portal in order to troubleshoot the exercise.

![20240620120840](https://i.imgur.com/EhAfy7w.png)

![20240620120801](https://i.imgur.com/t0BmZ0k.png)

![20240620120908](https://i.imgur.com/R2GoWVW.png)

![20240620121020](https://i.imgur.com/2XJj1DG.png)

## Preperations for exercise 2 (Integration with Governance Policies) -
1. Create a job template named K8S-Namespace, associate it with the project, secret and inventory created in the previous exercise. Make sure to associate the job template with the `07.Ansible-Tower-Integration/ansible-playbooks/namespace-playbook.yml` playbook.
2. Provide the participants with the token you created in `step 2` in the previous exercise alongside the web URL for the Ansible Automation Platform web server. Also, provide participants with a user / password to login into the web portal in order to troubleshoot the exercise.