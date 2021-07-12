# Simple DevSecOps Demo on Kind

![image](https://user-images.githubusercontent.com/106908/125296708-881f0800-e361-11eb-92c0-c62457a1a20b.png)

### Generate certificates

```bash
docker run --rm \
 -v ${PWD}/certs:/certs \
 hitch \
 sh /certs/generate-certs.sh sslip.io
```

https://blog.container-solutions.com/adding-self-signed-registry-certs-docker-mac

```bash
sudo security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain certs/ca.crt
```

**Restart docker**

### Setup kind cluster

```bash
brew install kind
```

```bash
$ kind version
kind v0.11.1 go1.16.4 darwin/amd64
```

```bash
kind create cluster --config kind.yaml
```

### Install Carvel tools

```bash
brew tap vmware-tanzu/carvel
brew install ytt kbld kapp imgpkg kwt vendir
```

or

```bash
curl -L https://carvel.dev/install.sh | bash
```

### Install Kapp Controller

```
ytt -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/download/v0.20.0/release.yml \
  -f apps/kapp-controller-config.yaml \
  -v namespace=kapp-controller \
  --data-value-file ca_crt=./certs/ca.crt \
  | kubectl apply -f -
```

### Install Cert Manager

```bash
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v0.16.1/cert-manager.yaml
```

### Install Contour

```bash
kubectl apply -f apps/contour.yaml
```

```bash
kubectl get app -n tanzu-system-ingress contour -o template='{{.status.deploy.stdout}}' -w
```

```bash
$ kubectl get app -n tanzu-system-ingress contour 
NAME      DESCRIPTION           SINCE-DEPLOY   AGE
contour   Reconcile succeeded   30s            91s
```

```bash
$ kubectl get service -n tanzu-system-ingress envoy                                                       
NAME    TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
envoy   NodePort   10.96.163.153   <none>        80:32676/TCP,443:31721/TCP   5m25s
```

```bash
ENVORY_CLUSTER_IP=$(kubectl get service -n tanzu-system-ingress envoy -o template='{{.spec.clusterIP}}')
```

### Install Harbor

```bash
HARBOR_HOST=harbor-$(echo $ENVORY_CLUSTER_IP | sed 's/\./-/g').sslip.io
```

```bash
ytt -f apps/harbor.yaml \
    -v harbor_host=${HARBOR_HOST} \
    --data-value-file=harbor_tls_crt=./certs/server.crt \
    --data-value-file=harbor_tls_key=./certs/server.key \
    | kubectl apply -f -
```

```bash
kubectl get app -n tanzu-system-registry harbor -o template='{{.status.deploy.stdout}}' -w
```

```bash
$ kubectl get app -n tanzu-system-registry harbor                                       
NAME     DESCRIPTION           SINCE-DEPLOY   AGE
harbor   Reconcile succeeded   39s            3m33s
```

```bash
$ kubectl get httpproxy -n tanzu-system-registry
NAME                      FQDN                                   TLS SECRET   STATUS   STATUS DESCRIPTION
harbor-httpproxy          harbor-10-96-163-153.sslip.io          harbor-tls   valid    Valid HTTPProxy
harbor-httpproxy-notary   notary.harbor-10-96-163-153.sslip.io   harbor-tls   valid    Valid HTTPProxy
```

```bash
docker exec kind-control-plane /etc/containerd/add-tls-containerd-config.sh ${HARBOR_HOST} /etc/containerd/certs.d/sslip.io.crt
```

```bash
$ docker exec kind-control-plane crictl info | jq .config.registry.configs
{
  "harbor-10-96-163-153.sslip.io": {
    "auth": null,
    "tls": {
      "insecure_skip_verify": false,
      "caFile": "/etc/containerd/certs.d/sslip.io.crt",
      "certFile": "",
      "keyFile": ""
    }
  }
}
```

```bash
sudo -E kwt net start
```

```bash
curl -v --cacert certs/ca.crt https://${HARBOR_HOST} 
```

```bash
docker login ${HARBOR_HOST} -u admin -p admin
```

Restart docker if you hit `Error response from daemon: Get https://${HARBOR_HOST}/v2/: x509: certificate signed by unknown authority`

### Install Tanzu Build Service

```bash
docker login registry.pivotal.io
```

```bash
curl -u admin:admin --cacert ./certs/ca.crt  -XPOST "https://${HARBOR_HOST}/api/v2.0/projects" -H "Content-Type: application/json" -d "{ \"project_name\": \"tanzu-build-service\"}"
```

```bash
imgpkg copy -b registry.pivotal.io/build-service/bundle:1.2.1 --to-repo ${HARBOR_HOST}/tanzu-build-service/build-service --registry-ca-cert-path certs/ca.crt
```

https://${HARBOR_HOST}/harbor/projects/2/repositories

![image](https://user-images.githubusercontent.com/106908/125250912-b97fdf80-e331-11eb-88ee-94adb342d7bb.png)

```bash
ytt -f apps/build-service.yaml \
    -v harbor_host=${HARBOR_HOST} \
    -v tanzunet_username="" \
    -v tanzunet_password="" \
    --data-value-file=ca_crt=./certs/ca.crt \
    | kubectl apply -f-
```

```bash
kubectl get app -n build-service build-service -o template='{{.status.deploy.stdout}}' -w
```

```bash
$ kubectl get app -n build-service build-service 
NAME            DESCRIPTION           SINCE-DEPLOY   AGE
build-service   Reconcile succeeded   11s            2m10s
```

```bash
REGISTRY_PASSWORD=admin kp secret create harbor --registry ${HARBOR_HOST} --registry-user admin  
```

```bash
curl -u admin:admin --cacert ./certs/ca.crt  -XPOST "https://${HARBOR_HOST}/api/v2.0/projects" -H "Content-Type: application/json" -d "{ \"project_name\": \"demo\"}"
PROJECT_ID=$(curl -s -u admin:admin --cacert ./certs/ca.crt "https://${HARBOR_HOST}/api/v2.0/projects?name=demo" | jq '.[0].project_id')
curl -u admin:admin --cacert ./certs/ca.crt  -XPUT "https://${HARBOR_HOST}/api/v2.0/projects/${PROJECT_ID}" -H "Content-Type: application/json" -d "{ \"metadata\": { \"auto_scan\" : \"true\" } }"
```

```bash
kp import -f descriptors/descriptor-100.0.69-java-only.yaml --registry-ca-cert-path certs/ca.crt 
```

```bash
kp image save hello-servlet --tag ${HARBOR_HOST}/demo/hello-servlet --git https://github.com/making/hello-servlet.git --git-revision master --wait
```

```
$ kp build list

BUILD    STATUS     IMAGE                                                                                                                       REASON
1        SUCCESS    harbor-10-96-163-153.sslip.io/demo/hello-servlet@sha256:d278bc8511cff9553f2f08142766b4bfe12f58ba774a1c4e7c27b69afc3d0d79    CONFIG
```

```
kp image delete hello-servlet
```

### Install Concourse

```bash
ytt -f apps/concourse.yaml \
    --data-value-file=ca_crt=./certs/ca.crt \
    --data-value-file=ca_key=./certs/ca.key \
    | kubectl apply -f-
```

```bash
kubectl get app -n concourse concourse -o template='{{.status.deploy.stdout}}' -w
```

```bash
$ kubectl get app -n concourse concourse    
NAME        DESCRIPTION           SINCE-DEPLOY   AGE
concourse   Reconcile succeeded   22s            101s
```

```bash
$ kubectl get ing -n concourse
NAME            CLASS    HOSTS                          ADDRESS   PORTS     AGE
concourse-web   <none>   concourse-127-0-0-1.sslip.io             80, 443   117s
```

```bash
curl --cacert ./certs/ca.crt -sL "https://concourse-127-0-0-1.sslip.io/api/v1/cli?arch=amd64&platform=darwin" > fly
install fly /usr/local/bin/fly
rm -f fly
```

```bash
fly -t demo login --ca-cert ./certs/ca.crt -c https://concourse-127-0-0-1.sslip.io -u admin -p admin
```

```bash
curl -sL https://gist.github.com/making/6e8443f091fef615e60ea6733f62b5db/raw/2d26d962d36ab8639f0a9e8dccb100f57f610d9d/unit-test.yml > unit-test.yml 
fly -t demo set-pipeline -p unit-test -c unit-test.yml --non-interactive
fly -t demo unpause-pipeline -p unit-test
fly -t demo trigger-job -j unit-test/unit-test --watch
fly -t demo destroy-pipeline -p unit-test --non-interactive
```

### DevSecOps pipeline

```bash
ssh-keygen -t rsa -b 4096 -f ${HOME}/.ssh/devsecops
```

Fork https://github.com/tanzu-japan/hello-tanzu-config and configure a deploy key above

![image](https://user-images.githubusercontent.com/106908/125279094-7a13bc00-e34e-11eb-8f9c-97ab7e96513e.png)


https://github.com/<YOUR_ACCOUNT>/hello-tanzu-config/settings/keys

`~/.ssh/devsecops.pub`

![image](https://user-images.githubusercontent.com/106908/125281904-c14f7c00-e351-11eb-9725-ef0c9c2d453a.png)

```yaml
cat <<EOF > pipeline-values.yaml
kubeconfig: |
$(kind get kubeconfig | sed -e 's/^/  /g' -e 's/127.0.0.1:.*$/kubernetes.default.svc.cluster.local/')
registry_host: ${HARBOR_HOST}
registry_project: demo
registry_username: admin
registry_password: admin
registry_ca: |
$(cat ./certs/ca.crt | sed -e 's/^/  /g')
app_name: hello-tanzu
app_source_uri: https://github.com/tanzu-japan/hello-tanzu.git
app_source_branch: main
app_config_uri: git@github.com:making/hello-tanzu-config.git # <--- CHANGEME
app_config_branch: main
app_config_private_key: |
$(cat ${HOME}/.ssh/devsecops | sed -e 's/^/  /g')
app_external_url: https://hello-tanzu-$(echo $ENVORY_CLUSTER_IP | sed 's/\./-/g').sslip.io
git_email: makingx+bot@gmail.com
git_name: making-bot
EOF
```

```
fly -t demo set-pipeline -p devsecops -c devsecops.yaml -l pipeline-values.yaml --non-interactive
fly -t demo unpause-pipeline -p devsecops
```

![image](https://user-images.githubusercontent.com/106908/125284284-3ae86980-e354-11eb-8de6-915444387eb1.png)

![image](https://user-images.githubusercontent.com/106908/125284636-a6323b80-e354-11eb-85bb-cb12fb9c1abe.png)

> `deploy-to-k8s` job should fail with `ytt: Error: Checking file 'app-config/demo/values.yaml': lstat app-config/demo/values.yaml: no such file or directory` . 

![image](https://user-images.githubusercontent.com/106908/125284748-d24dbc80-e354-11eb-8de7-7fa23dd8857c.png)

![image](https://user-images.githubusercontent.com/106908/125285357-894a3800-e355-11eb-8fd3-00dd9c0b1134.png)

![image](https://user-images.githubusercontent.com/106908/125284837-ebef0400-e354-11eb-95e2-b5ce061b07ef.png)

![image](https://user-images.githubusercontent.com/106908/125284958-0b862c80-e355-11eb-8930-38f265a5d4ef.png)

![image](https://user-images.githubusercontent.com/106908/125285040-2c4e8200-e355-11eb-8a64-7f3203b025f4.png)

```bash
kp import -f descriptors/descriptor-100.0.110-java-only.yaml --registry-ca-cert-path certs/ca.crt 
```

![image](https://user-images.githubusercontent.com/106908/125287994-97e61e80-e358-11eb-8a17-8ff65d2c30f2.png)

![image](https://user-images.githubusercontent.com/106908/125296692-83f2ea80-e361-11eb-930d-5781f20f03ad.png)

![image](https://user-images.githubusercontent.com/106908/125306528-434b9f00-e36a-11eb-9d7e-44483c532dbc.png)

![image](https://user-images.githubusercontent.com/106908/125296708-881f0800-e361-11eb-92c0-c62457a1a20b.png)

![image](https://user-images.githubusercontent.com/106908/125297499-3fb41a00-e362-11eb-8a56-1ecede016e07.png)

Update builder

```bash
TANZUNET_USERNAME=****
TANZUNET_PASSWORD=****

ytt -f apps/build-service.yaml \
    -v harbor_host=${HARBOR_HOST} \
    -v tanzunet_username="${TANZUNET_USERNAME}" \
    -v tanzunet_password="${TANZUNET_PASSWORD}" \
    --data-value-file=ca_crt=./certs/ca.crt \
    | kubectl apply -f-
kubectl get app -n build-service build-service -o template='{{.status.deploy.stdout}}' -w
```

```
$ kubectl get tanzunetdependencyupdater -n build-service 
NAME                 DESCRIPTORVERSION   READY
dependency-updater   100.0.122           True
```

![image](https://user-images.githubusercontent.com/106908/125307696-4004e300-e36b-11eb-915c-3a673c28dc40.png)

![image](https://user-images.githubusercontent.com/106908/125307865-64f95600-e36b-11eb-9972-b37803e504d7.png)

![image](https://user-images.githubusercontent.com/106908/125306984-a0dfeb80-e36a-11eb-8496-a7f1f51e315d.png)

![image](https://user-images.githubusercontent.com/106908/125307551-1cda3380-e36b-11eb-8ec6-bb5cfd4f2404.png)

