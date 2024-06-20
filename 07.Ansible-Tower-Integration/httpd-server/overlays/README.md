# httpd container used for iso


**Manually setup deployment**
```
oc apply -k httpd-server/overlays/default
```

**Deploy using URL**
```
oc apply -k https://github.com/tosin2013/kubevirt-gitops/components/dependencies/httpd-server/overlays/default
```
