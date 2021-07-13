# Simple DevSecOps Demo on Kind

This tutorial shows how to build a simple DevSecOps pipeline using [Tanzu Build Service](https://docs.pivotal.io/build-service/1-2/index.html), [Harbor](https://goharbor.io/), [Carvel](https://carvel.dev) and [Concourse](https://concourse-ci.org/).

![image](https://user-images.githubusercontent.com/106908/125296708-881f0800-e361-11eb-92c0-c62457a1a20b.png)

Clone this repository and change to that directory.
```
git clone https://github.com/tanzu-japan/devsecops-demo.git
cd devsecops-demo
```

> This tutorial has been tested on Mac. It probably works on Linux with a few step changes. It does not work on Windows.

## Generate certificates

First of all, generate a self-signed certificate that is used throughout this tutorial.

Run the following command.

```bash
docker run --rm \
 -v ${PWD}/certs:/certs \
 hitch \
 sh /certs/generate-certs.sh sslip.io
```


Let Laptop trust the generated CA certificate.

```bash
# https://blog.container-solutions.com/adding-self-signed-registry-certs-docker-mac
sudo security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain certs/ca.crt
```
Don't forget to **restart Docker** after running the above command.

## Setup kind cluster

Install Kind.

```bash
brew install kind
```

Confirmed to work with the following versions.

```bash
$ kind version
kind v0.11.1 go1.16.4 darwin/amd64
```

Create a Kubernetes cluster on Docker using Kind.

```bash
kind create cluster --config kind.yaml
```

## Install Carvel tools

Install Carvel tools.

```bash
brew tap vmware-tanzu/carvel
brew install ytt kbld kapp imgpkg kwt vendir
```

or

```bash
curl -L https://carvel.dev/install.sh | bash
```

## Install Kapp Controller

Install Kapp Controller. 
Add a ConfigMap for the Kapp Controller to trust the CA certificate generated above.

```
ytt -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/download/v0.20.0/release.yml \
  -f apps/kapp-controller-config.yaml \
  -v namespace=kapp-controller \
  --data-value-file ca_crt=./certs/ca.crt \
  | kubectl apply -f -
```

> If you are running this tutorial using Tanzu Kubernetes Grid instead of Kind, run the following command instead.
> ```bash
> ytt -f apps/kapp-controller-config.yaml \
> -v namespace=tkg-system \
> --data-value-file ca_crt=./certs/ca.crt \
> | kubectl apply -f -
> ```

## Install Cert Manager

Install Cert Manager.

```bash
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v0.16.1/cert-manager.yaml
```

## Install Contour

Install Contour.

```bash
kubectl apply -f apps/contour.yaml
```

Run the following command and wait until `Succeeded` is output.

```bash
kubectl get app -n tanzu-system-ingress contour -o template='{{.status.deploy.stdout}}' -w
```

Run the following command and confirm that `Reconcile succeeded` is output.

```bash
$ kubectl get app -n tanzu-system-ingress contour 
NAME      DESCRIPTION           SINCE-DEPLOY   AGE
contour   Reconcile succeeded   30s            91s
```

Check Envoy's Cluster IP.

```bash
$ kubectl get service -n tanzu-system-ingress envoy                                                       
NAME    TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
envoy   NodePort   10.96.163.153   <none>        80:32676/TCP,443:31721/TCP   5m25s
```

Set this IP to a variable named `ENVOY_CLUSTER_IP` for later use.

```bash
ENVOY_CLUSTER_IP=$(kubectl get service -n tanzu-system-ingress envoy -o template='{{.spec.clusterIP}}')
```

## Install Harbor

Set the Hostname to route requests to Harbor as follows:

```bash
HARBOR_HOST=harbor-$(echo $ENVOY_CLUSTER_IP | sed 's/\./-/g').sslip.io
# harbor-10-96-163-153.sslip.io
```

Install Harbor with the following command:

```bash
ytt -f apps/harbor.yaml \
    -v harbor_host=${HARBOR_HOST} \
    --data-value-file=harbor_tls_crt=./certs/server.crt \
    --data-value-file=harbor_tls_key=./certs/server.key \
    | kubectl apply -f -
```

Run the following command and wait until `Succeeded` is output.

```bash
kubectl get app -n tanzu-system-registry harbor -o template='{{.status.deploy.stdout}}' -w
```

Run the following command and confirm that `Reconcile succeeded` is output.

```bash
$ kubectl get app -n tanzu-system-registry harbor                                       
NAME     DESCRIPTION           SINCE-DEPLOY   AGE
harbor   Reconcile succeeded   39s            3m33s
```

Check if the FQDN of the HTTPProxy object matches `HARBOR_HOST`.

```bash
$ kubectl get httpproxy -n tanzu-system-registry
NAME                      FQDN                                   TLS SECRET   STATUS   STATUS DESCRIPTION
harbor-httpproxy          harbor-10-96-163-153.sslip.io          harbor-tls   valid    Valid HTTPProxy
harbor-httpproxy-notary   notary.harbor-10-96-163-153.sslip.io   harbor-tls   valid    Valid HTTPProxy
```

Change Kind's Containerd `config.toml` so that it uses the CA certificate generated above for this `HARBOR_HOST`.

```bash
docker exec kind-control-plane /etc/containerd/add-tls-containerd-config.sh ${HARBOR_HOST} /etc/containerd/certs.d/sslip.io.crt
```

Make sure that the change is reflected.

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

Then use `kwt` to make it accessible directly from the laptop into the k8s cluster.
Run the following command in **another terminal**.
```bash
sudo -E kwt net start
```

Make sure you can access Harbor with curl.

```bash
curl -v --cacert certs/ca.crt https://${HARBOR_HOST} 
```

Log in to Harbor.

```bash
docker login ${HARBOR_HOST} -u admin -p admin
```

Restart Docker if you hit `Error response from daemon: Get https://${HARBOR_HOST}/v2/: x509: certificate signed by unknown authority`

## Install Tanzu Build Service

Log in to [Tanzu Network](https://network.pivotal.io/)

```bash
docker login registry.pivotal.io
```

Create a project to store images for Tanzu Build Service in Harbor.

```bash
curl -u admin:admin --cacert ./certs/ca.crt  -XPOST "https://${HARBOR_HOST}/api/v2.0/projects" -H "Content-Type: application/json" -d "{ \"project_name\": \"tanzu-build-service\"}"
```

Run the following command to copy the Tanzu Build Service images from Tanzu Network to Harbor.

```bash
imgpkg copy -b registry.pivotal.io/build-service/bundle:1.2.1 --to-repo ${HARBOR_HOST}/tanzu-build-service/build-service --registry-ca-cert-path certs/ca.crt
```

Go to `https://${HARBOR_HOST}/harbor/projects/2/repositories` and make sure Tanzu Build Service images have been uploaded.

![image](https://user-images.githubusercontent.com/106908/125250912-b97fdf80-e331-11eb-88ee-94adb342d7bb.png)

Then install Tanzu Build Service with the following command.

```bash
ytt -f apps/build-service.yaml \
    -v harbor_host=${HARBOR_HOST} \
    -v tanzunet_username="" \
    -v tanzunet_password="" \
    --data-value-file=ca_crt=./certs/ca.crt \
    | kubectl apply -f-
```

Run the following command and wait until `Succeeded` is output.

```bash
kubectl get app -n build-service build-service -o template='{{.status.deploy.stdout}}' -w
```

Run the following command and confirm that `Reconcile succeeded` is output.

```bash
$ kubectl get app -n build-service build-service 
NAME            DESCRIPTION           SINCE-DEPLOY   AGE
build-service   Reconcile succeeded   11s            2m10s
```

Create a Secret in `default` namespace that Tanzu Build Service uses to push built images to Harbor.

```bash
REGISTRY_PASSWORD=admin kp secret create harbor --registry ${HARBOR_HOST} --registry-user admin  
```

Create a project in Harbor to store images of the Demo application.
Also, use only Builder for Java to reduce upload time.

```bash
curl -u admin:admin --cacert ./certs/ca.crt  -XPOST "https://${HARBOR_HOST}/api/v2.0/projects" -H "Content-Type: application/json" -d "{ \"project_name\": \"demo\"}"
PROJECT_ID=$(curl -s -u admin:admin --cacert ./certs/ca.crt "https://${HARBOR_HOST}/api/v2.0/projects?name=demo" | jq '.[0].project_id')
curl -u admin:admin --cacert ./certs/ca.crt  -XPUT "https://${HARBOR_HOST}/api/v2.0/projects/${PROJECT_ID}" -H "Content-Type: application/json" -d "{ \"metadata\": { \"auto_scan\" : \"true\" } }"
```

Upload ClusterBuilder / ClusterStore / ClusterStack to Tanzu Build Service.
Here we intentionally upload an older version.

```bash
kp import -f descriptors/descriptor-100.0.69-java-only.yaml --registry-ca-cert-path certs/ca.crt 
```

To check the operation, we will build a simple application.

```bash
kp image save hello-servlet --tag ${HARBOR_HOST}/demo/hello-servlet --git https://github.com/making/hello-servlet.git --git-revision master --wait
```

Make sure the Build is successful.

```
$ kp build list

BUILD    STATUS     IMAGE                                                                                                                       REASON
1        SUCCESS    harbor-10-96-163-153.sslip.io/demo/hello-servlet@sha256:d278bc8511cff9553f2f08142766b4bfe12f58ba774a1c4e7c27b69afc3d0d79    CONFIG
```

Delete the image after checking the operation.

```
kp image delete hello-servlet
```

## Install Concourse

Install Concourse with the following command.

```bash
ytt -f apps/concourse.yaml \
    --data-value-file=ca_crt=./certs/ca.crt \
    --data-value-file=ca_key=./certs/ca.key \
    | kubectl apply -f-
```

Run the following command and wait until `Succeeded` is output.

```bash
kubectl get app -n concourse concourse -o template='{{.status.deploy.stdout}}' -w
```

Run the following command and confirm that `Reconcile succeeded` is output.

```bash
$ kubectl get app -n concourse concourse    
NAME        DESCRIPTION           SINCE-DEPLOY   AGE
concourse   Reconcile succeeded   22s            101s
```

Check the ingress for Concourse.

```bash
$ kubectl get ing -n concourse
NAME            CLASS    HOSTS                          ADDRESS   PORTS     AGE
concourse-web   <none>   concourse-127-0-0-1.sslip.io             80, 443   117s
```

Install `fly` CLI as follows:

```bash
curl --cacert ./certs/ca.crt -sL "https://concourse-127-0-0-1.sslip.io/api/v1/cli?arch=amd64&platform=darwin" > fly
install fly /usr/local/bin/fly
rm -f fly
```

Log in to the Concourse.

```bash
fly -t demo login --ca-cert ./certs/ca.crt -c https://concourse-127-0-0-1.sslip.io -u admin -p admin
```

To check the operation, set a simple pipeline and execute the job.

```bash
curl -sL https://gist.github.com/making/6e8443f091fef615e60ea6733f62b5db/raw/2d26d962d36ab8639f0a9e8dccb100f57f610d9d/unit-test.yml > unit-test.yml 
fly -t demo set-pipeline -p unit-test -c unit-test.yml --non-interactive
fly -t demo unpause-pipeline -p unit-test
fly -t demo trigger-job -j unit-test/unit-test --watch
fly -t demo destroy-pipeline -p unit-test --non-interactive
```

## DevSecOps pipeline
 
Generate an SSH key for use with GitOps.

```bash
ssh-keygen -t rsa -b 4096 -f ${HOME}/.ssh/devsecops
```

Fork [https://github.com/tanzu-japan/hello-tanzu-config](https://github.com/tanzu-japan/hello-tanzu-config) to your account. 

![image](https://user-images.githubusercontent.com/106908/125279094-7a13bc00-e34e-11eb-8f9c-97ab7e96513e.png)

Go to `https://github.com/<YOUR_ACCOUNT>/hello-tanzu-config/settings/keys
` and configure `$HOME/.ssh/devsecops.pub` generated above as a deploy key.

Don't forget to check "Allow write access".

![image](https://user-images.githubusercontent.com/106908/125281904-c14f7c00-e351-11eb-9725-ef0c9c2d453a.png)

The following command creates a set of variables to pass to the Concourse pipeline.

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
app_external_url: https://hello-tanzu-$(echo $ENVOY_CLUSTER_IP | sed 's/\./-/g').sslip.io
git_email: makingx+bot@gmail.com
git_name: making-bot
EOF
```

Change `app_source_uri` and `app_config_uri` according to your environment.

Set up the pipeline for DevSecOps with the following command:

```
fly -t demo set-pipeline -p devsecops -c devsecops.yaml -l pipeline-values.yaml --non-interactive
fly -t demo unpause-pipeline -p devsecops
```

The following jobs will be automatically triggered within 1 minute.

![image](https://user-images.githubusercontent.com/106908/125284284-3ae86980-e354-11eb-8de6-915444387eb1.png)

Make sure the `unit-test` job is successful and green.

![image](https://user-images.githubusercontent.com/106908/125284636-a6323b80-e354-11eb-85bb-cb12fb9c1abe.png)

`deploy-to-k8s` job should fail with the following message:

```
ytt: Error: Checking file 'app-config/demo/values.yaml': lstat app-config/demo/values.yaml: no such file or directory` .
``` 
This is as expected, so don't worry.

After a while `kpack-build` job will succeed and turn green.

![image](https://user-images.githubusercontent.com/106908/125284748-d24dbc80-e354-11eb-8de7-7fa23dd8857c.png)

You can check the kpack log at build time by checking `kpack-build` job.

![image](https://user-images.githubusercontent.com/106908/125285357-894a3800-e355-11eb-8fd3-00dd9c0b1134.png)

Since the image was created by Tanzu Build Service (Kpack), so after a while `vulnerability-scan` job will be triggered automatically.

![image](https://user-images.githubusercontent.com/106908/125284837-ebef0400-e354-11eb-95e2-b5ce061b07ef.png)

`vulnerability-scan` job should fail at this stage as it contains vulnerable dependencies.

![image](https://user-images.githubusercontent.com/106908/125284958-0b862c80-e355-11eb-8930-38f265a5d4ef.png)

You can find out why this job failed and where the unresolved vulnerabilities are by looking at the details of the `vulnerability-scan` job.

![image](https://user-images.githubusercontent.com/106908/125285040-2c4e8200-e355-11eb-8a64-7f3203b025f4.png)

Upload newer ClusterBuilder / ClusterStore / ClusterStack to Tanzu Build Service.

```bash
kp import -f descriptors/descriptor-100.0.110-java-only.yaml --registry-ca-cert-path certs/ca.crt 
```

When the upload is complete, Tanzu Build Service will detect the change and automatically rebuild the image with newer dependencies. This will automatically trigger `vulnerability-scan` job again.

![image](https://user-images.githubusercontent.com/106908/125287994-97e61e80-e358-11eb-8a17-8ff65d2c30f2.png)

This time `vulnerability-scan` job will succeed and the changes are pushed to the forked hello-tanzu-config git repository.

![image](https://user-images.githubusercontent.com/106908/125296692-83f2ea80-e361-11eb-930d-5781f20f03ad.png)

> By the time you run this tutorial, this dependencies may become obsolete and the `vulnerability-scan` job may fail.

Make sure the following file is pushed on Github.

![image](https://user-images.githubusercontent.com/106908/125306528-434b9f00-e36a-11eb-9d7e-44483c532dbc.png)

Finally all the jobs were successful and turned green.

![image](https://user-images.githubusercontent.com/106908/125296708-881f0800-e361-11eb-92c0-c62457a1a20b.png)

Go to `app_external_url` configured in `pipeline-values.yaml` with a browser.

![image](https://user-images.githubusercontent.com/106908/125297499-3fb41a00-e362-11eb-8a56-1ecede016e07.png)

Yeah, it works 👍.

## Automatically update Tanzu Build Service dependencies.

TanzuNetDependencyUpdater which will allow your Tanzu Build Service Cluster to automatically update its dependencies when new dependency descriptors are published to TanzuNet since [Tanzu Build Service 1.2](https://docs.pivotal.io/build-service/1-2/release-notes.html#1-2-0).

Update Tanzu Build Service by configuring your Tanzu Network credentials.

```bash
TANZUNET_USERNAME=****
TANZUNET_PASSWORD=****

ytt -f apps/build-service.yaml \
    -v harbor_host=${HARBOR_HOST} \
    -v tanzunet_username="${TANZUNET_USERNAME}" \
    -v tanzunet_password="${TANZUNET_PASSWORD}" \
    --data-value-file=ca_crt=./certs/ca.crt \
    | kubectl apply -f-
```

Run the following command and wait until `Succeeded` is output. It will take a little longer.

```
kubectl get app -n build-service build-service -o template='{{.status.deploy.stdout}}' -w
```

Get the TanzuNetDependencyUpdater to make sure the description version is up to date.

```
$ kubectl get tanzunetdependencyupdater -n build-service 
NAME                 DESCRIPTORVERSION   READY
dependency-updater   100.0.122           True
```

Tanzu Build Service will detect the change and automatically rebuild the image with newer dependencies. This will automatically trigger `vulnerability-scan` job again.

![image](https://user-images.githubusercontent.com/106908/125307696-4004e300-e36b-11eb-915c-3a673c28dc40.png)

Then `update-config` job will also be triggered automatically.

![image](https://user-images.githubusercontent.com/106908/125307865-64f95600-e36b-11eb-9972-b37803e504d7.png)

You can check the changed contents of the image on Github.

![image](https://user-images.githubusercontent.com/106908/125306984-a0dfeb80-e36a-11eb-8496-a7f1f51e315d.png)

The updated image will be deployed to k8s.

![image](https://user-images.githubusercontent.com/106908/125307551-1cda3380-e36b-11eb-8ec6-bb5cfd4f2404.png)

With this pipeline, the image is automatically updated and shipped to k8s every time a new Stack, Store or Builder is released 🙌.

## (Bonus) Detects the use of vulnerable libraries

Fork [https://github.com/tanzu-japan/hello-tanzu](https://github.com/tanzu-japan/hello-tanzu) to your account.

![image](https://user-images.githubusercontent.com/106908/125382012-dec32b00-e3cf-11eb-9f2c-10c335fd82e9.png)


Change `app_config_uri` in pipeline-values.yaml to the forked uri and update the pipeline

```
fly -t demo set-pipeline -p devsecops -c devsecops.yaml -l pipeline-values.yaml --non-interactive
```

Edit `pom.xml` in the forked repository and add a vulnerable dependency bellow inside `<dependencies>`:

```xml
		<dependency>
			<groupId>org.apache.commons</groupId>
			<artifactId>commons-collections4</artifactId>
			<version>4.0</version>
		</dependency>
```

![image](https://user-images.githubusercontent.com/106908/125382505-bb4cb000-e3d0-11eb-89e1-d7ddcc2ccdb1.png)

then commit the change.

![image](https://user-images.githubusercontent.com/106908/125382609-eb944e80-e3d0-11eb-860d-b6b11b00fee2.png)

`unit-test` job will be triggered in less than 1min.

![image](https://user-images.githubusercontent.com/106908/125382666-0bc40d80-e3d1-11eb-9987-322c5064a5b9.png)

then `kpack-build` job will follow.

![image](https://user-images.githubusercontent.com/106908/125382696-1c748380-e3d1-11eb-8138-3d02d7bda4ea.png)

After the new image is pushed to Harbor, `vulnerability-scan` job will start. 

![image](https://user-images.githubusercontent.com/106908/125382814-56de2080-e3d1-11eb-8e36-8ebd5cfc3589.png)

The job should fail.

![image](https://user-images.githubusercontent.com/106908/125382887-7bd29380-e3d1-11eb-88a6-4879536a39ca.png)

Because we intentionally used the vulnerable commons-collections 4.0 as reported 😈

![image](https://user-images.githubusercontent.com/106908/125382855-6c534a80-e3d1-11eb-9e3e-1beb013e51df.png)

Let's update the library and fix the vulnerability as follows:

```xml
		<dependency>
			<groupId>org.apache.commons</groupId>
			<artifactId>commons-collections4</artifactId>
			<version>4.4</version>
		</dependency>
```

Edit `pom.xml` and commit the change:

![image](https://user-images.githubusercontent.com/106908/125383118-e257b180-e3d1-11eb-8952-58373cc362e4.png)

After `unit-test` and `kpack-build` succeeded again, `vulnerability-scan` job will resume.

![image](https://user-images.githubusercontent.com/106908/125383321-35c9ff80-e3d2-11eb-9344-05969043b629.png)

Since the vulnerability has been fixed the job will be successful, and `update-config` job is started.

![image](https://user-images.githubusercontent.com/106908/125383382-48443900-e3d2-11eb-92d4-0194a0e8f950.png)

And the "safe image" will be shipped to k8s.

![image](https://user-images.githubusercontent.com/106908/125383449-5eea9000-e3d2-11eb-86a6-c7a57b316d57.png)

---
You've built a simple DevSecOps pipeline. Congratulations 🎉.
