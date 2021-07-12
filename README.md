# Simple DevSecOps Demo on Kind

![image](https://user-images.githubusercontent.com/106908/125226079-59764280-e30b-11eb-8886-b0e38acdcfea.png)

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
  -f kapp-controller-config.yaml \
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
kubectl apply -f contour.yaml
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
NAME    TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)                      AGE
envoy   NodePort   10.96.245.72   <none>        80:30172/TCP,443:31841/TCP   4m47s
```

```bash
ENVORY_CLUSTER_IP=$(kubectl get service -n tanzu-system-ingress envoy -o template='{{.spec.clusterIP}}')
```

### Install Harbor

```bash
HARBOR_HOST=harbor-$(echo $ENVORY_CLUSTER_IP | sed 's/\./-/g').sslip.io
```

```bash
docker exec kind-control-plane /etc/containerd/add-tls-containerd-config.sh ${HARBOR_HOST} /etc/containerd/certs.d/sslip.io.crt
```

```bash
docker exec kind-control-plane crictl info
```

```bash
ytt -f harbor.yaml \
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
NAME                      FQDN                                  TLS SECRET   STATUS   STATUS DESCRIPTION
harbor-httpproxy          harbor-10-96-245-72.sslip.io          harbor-tls   valid    Valid HTTPProxy
harbor-httpproxy-notary   notary.harbor-10-96-245-72.sslip.io   harbor-tls   valid    Valid HTTPProxy
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

```bash
ytt -f build-service.yaml \
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
build-service   Reconcile succeeded   23s            3m40s
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
brew install pivotal/tap/pivnet-cli
TANZU_NET_API_TOKEN=....
pivonet login --api-token=${TANZU_NET_API_TOKEN}
pivnet download-product-files --product-slug='tbs-dependencies' --release-version='100.0.69' --product-file-id=891120
kp import -f descriptor-100.0.69.yaml --registry-ca-cert-path certs/ca.crt 
```


```bash
kp image save hello-servlet --tag ${HARBOR_HOST}/demo/hello-servlet --git https://github.com/making/hello-servlet.git --git-revision master --wait
```

### Install Concourse

```bash
ytt -f concourse.yaml \
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
fly -t demo set-pipeline -p unit-test -c unit-test.yml
fly -t demo unpause-pipeline -p unit-test
fly -t demo trigger-job -j unit-test/unit-test --watch
fly -t demo destroy-pipeline -p unit-test
```

### DevSecOps pipeline

```bash
ssh-keygen -t rsa -b 4096 -f ${HOME}/.ssh/devsecops
```

**TODO**: Fork https://github.com/making/hello-tanzu-config and configure a deploy key above

```yaml
cat <<EOF > pipeline-values.yaml
kubeconfig: |
$(kind get kubeconfig | sed -e 's/^/  /g' -e 's|127.0.0.1:63653|kubernetes.default.svc.cluster.local|')
registry_host: ${HARBOR_HOST}
registry_project: demo
registry_username: admin
registry_password: admin
registry_ca: |
$(cat ./certs/ca.crt | sed -e 's/^/  /g')
app_name: hello-tanzu
app_source_uri: https://github.com/making/hello-tanzu.git
app_source_branch: main
app_config_uri: git@github.com:making/hello-tanzu-config.git
app_config_branch: main
app_config_private_key: |
$(cat ${HOME}/.ssh/devsecops | sed -e 's/^/  /g')
app_external_url: https://hello-tanzu-127-0-0-1.sslip.io
git_email: makingx+bot@gmail.com
git_name: making-bot
EOF
```

```
fly -t demo set-pipeline -p devsecops -c devsecops.yaml -l pipeline-values.yaml
fly -t demo unpause-pipeline -p devsecops
```

![image](https://user-images.githubusercontent.com/106908/125226079-59764280-e30b-11eb-8886-b0e38acdcfea.png)

![image](https://user-images.githubusercontent.com/106908/125226535-3d26d580-e30c-11eb-9423-22affd06a3dc.png)

Update builder

```bash
ytt -f build-service.yaml \
    -v harbor_host=${HARBOR_HOST} \
    -v tanzunet_username="<Tanzu Net Username>" \
    -v tanzunet_password="<Tanzu Net Password>" \
    --data-value-file=ca_crt=./certs/ca.crt \
    | kubectl apply -f-
kubectl get app -n build-service build-service -o template='{{.status.deploy.stdout}}' -w
```

![image](https://user-images.githubusercontent.com/106908/125226334-dbff0200-e30b-11eb-8999-539775b554ec.png)

![image](https://user-images.githubusercontent.com/106908/125226354-e91bf100-e30b-11eb-9824-b114981d019e.png)
