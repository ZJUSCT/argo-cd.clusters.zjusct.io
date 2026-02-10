Modifications to be done to helm charts:

0. currently, the folder contains AI generated helm values. To prevent hallucination, please fetch the original helm values file from the first comment line of the values file. It's my personally habit to add the reference file as the first comment line of the helm values file.

1. prefix all images with harbor.clusters.zjusct.io

for example: 

    - ubuntu -> harbor.clusters.zjusct.io/hub.docker.com/library/ubuntu
    - quay.io/prometheus/prometheus -> harbor.clusters.zjusct.io/quay.io/prometheus/prometheus

2. use sealedsecret for all critical passwords, and store the sealedsecret in git. Remember to kubeseal --validate the sealedsecret before committing to git.

3. remember to kubectl kustomize --enable-helm . to validate the helm charts before committing to git.

4. To expose services: prefer using gateway api than ingress. Service dns domain should be <svc>.clusters.zjusct.io. If multiple hosts are supported, add <>.s.clusters.zjusct.io as well.
