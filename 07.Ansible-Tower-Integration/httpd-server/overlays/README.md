# httpd container used for iso


**Manually setup deployment**
```
oc apply -k httpd-server/overlays/default
```

**Deploy using URL**
```
oc apply -k https://github.com/tosin2013/rhacm-workshop/tree/master/07.Ansible-Tower-Integration/httpd-server/overlays/default
```
