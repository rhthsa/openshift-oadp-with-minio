# OADP with MinIO
- [OADP with MinIO](#oadp-with-minio)
  - [MinIO](#minio)
  - [Sample Todo App](#sample-todo-app)
  - [OADP Operator](#oadp-operator)
    - [Backup](#backup)
    - [Schedule Backup](#schedule-backup)
    - [Restore](#restore)
  - [Restore from another cluster](#restore-from-another-cluster)
  - [Minio Client](#minio-client)

## MinIO

- Install Minio Operator from OperatorHub
  
  ![](images/minio-operator-operatorhub.png)


- Install [minIO kubctl plugin](https://docs.min.io/minio/k8s/tenant-management/deploy-minio-tenant-using-commandline.html)


- Initial tenant
  
  ```bash
  kubectl minio init -n openshift-operators
  ```

- Check service on namespace openshift-operators
  
  ```bash
  oc get svc/console -n openshift-operators
  ```

  Output

  ```bash
  NAME      TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)             AGE
  console   ClusterIP   172.30.109.205   <none>        9090/TCP,9443/TCP   11m
  ```

- Create route for MinIO console
  
  ```bash
  oc create route edge minio-console --service=console --port=9090 -n openshift-operators
  ```

  ![](images/minio-dev-console-topology.png)

- Login with JWT token extracted from secret

  ```bash
  oc get secret/console-sa-secret -o jsonpath='{.data.token}' -n openshift-operators | base64 -d
  ```
  
  ![](images/minio-operator-console.png)

- Create project minio
  
  ```bash
  oc new-project minio --description="Object Storage for OADP"
  ```

- Check ID from minio

  ```bash
  oc get ns minio -o=jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}'
  ```
    
  Write down the number before slash (/). You need this ID when configure tenant

- Create tenant with MinIO Console
  - Setup: tenant name, namespace, capacity and requests/limits
    
    ![](images/minio-console-setup-tenant.png)

  - Configure: Disable expose MinIO Service and Console (We will create OpenShift's route manually) enable security context with number extracted from namespace supplemental-groups

    ![](images/minio-console-configure.png)
  
  - Pod placement: Set to None in case your environment is small not have many nodes to do pod anti-affinity
    
    ![](images/minio-console-pod-placement.png)

  - Identiy Provider: add user
  
    ![](images/minio-console-identity-provider.png)

  - Security: Disable TLS

    ![](images/minio-console-security.png)

  - Audit: Disabled
  - Monitoring: Disabled
  - Click Create and wait for tenant creation

    ![](images/minio-tenant-creation-on-progress.png)

- Edit Security Context for console
  - Login to OpenShift Admin Console
  - Select namespace minio
  - Operators->Installed Operators->Minio Operator->Tenant
  - Edit YAML. Add following lines to spec:
    
    ```yaml
    console:
      securityContext:
        fsGroup: <supplemental-groups>
        runAsGroup: <supplemental-groups>
        runAsNonRoot: true
        runAsUser: <supplemental-groups> 
    ```

- Verify that Tenant is up and running

  ![](images/minio-console-tenant-ready.png)

  Details

  ![](images/minio-console-tenant.png)

  check stateful set

  ```bash
  oc get statefulset -n minio
  ```

  Output

  ```bash
  NAME              READY   AGE
  cluster1-pool-0   4/4     18m
  ```

- Verify CPU and Memory consumed by MinIO in namesapce minio
  
  CPU utilization 

  ![](images/minio-cpu-request-limit.png)

  Memory utilization

  ![](images/minio-memory-reqeust-limit.png)

- Create Route for Tenant Console

  ```bash
  oc create route edge oadp-console --service=oadp-console --port=9090 -n minio
  ```

- Create Route for Minio

  ```bash
  oc create route edge minio --service=minio -n minio
  ```

- Login to tenant console with user you specified while creating tenant and create bucket name cluster1 
  
  Login page

  ![](images/tenant-console-login.png)

  Create bucket

  ![](images/tenant-console-create-bucket.png)

- Create Service Account for OADP
  
  ![](images/tenant-create-service-account.png)

## Sample Todo App

- Deploy todo app to namespace todo with kustomize.
  
  ```bash
  oc create -k todo-kustomize/overlays/jvm
  ```
  Output

  ```bash
  namespace/todo created
  secret/todo-db created
  service/todo created
  service/todo-db created
  persistentvolumeclaim/todo-db created
  deployment.apps/todo created
  deployment.apps/todo-db created
  servicemonitor.monitoring.coreos.com/todo created
  route.route.openshift.io/todo created
  ```

- Add couple of your tasks to todo app
  
  ![](images/todo-app.png)
  
## OADP Operator

- Install OADP Operator from OperatorHub

  ![](images/oadp-operator-operatorhub.png)

- Edit file [credentials-velero](credentials-velero) with ID and key of Service Account you created for tenant.

  ```ini
  [default]
  aws_access_key_id=<ID>
  aws_secret_access_key=<KEY>
  ```

- Create credentials for OADP to access MinIO bucket

  ```bash
  oc create secret generic cloud-credentials -n openshift-adp --from-file cloud=credentials-velero
  ```

- Create [DataProtectionApplication](config/DataProtectionApplication.yaml)

  ```yaml
  apiVersion: oadp.openshift.io/v1alpha1
  kind: DataProtectionApplication
  metadata:
    name: app-backup
    namespace: openshift-adp
  spec:
    configuration:
      velero:
        defaultPlugins:
          - aws 
          - openshift # Mandatory
      restic:
        enable: true # If you don't have CSI then you need to enable restic
    backupLocations:
      - velero:
          config:
            profile: "default"
            region: minio
            s3Url: http://minio.minio.svc.cluster.local:80 
            insecureSkipTLSVerify: "true"
            s3ForcePathStyle: "true"
          provider: aws
          default: true
          credential:
            key: cloud
            name: cloud-credentials # Default. Can be removed 
          objectStorage:
            bucket: cluster1
            prefix: oadp # Optional if this bucket use with more than app
  ```
  
  Run following command
  
  ```bash
  oc create -f config/DataProtectionApplication.yaml
  ```

- Verify that BackupStorageLocation is ready
  
  ```bash
  oc get BackupStorageLocation -n openshift-adp
  ```
  
  Output
  
  ```
  NAME           PHASE       LAST VALIDATED   AGE    DEFAULT
  app-backup-1   Available   36s              2m2s   true
  ```
  
  ![](images/oadp-operator-backupstoragelocation.png)

### Backup

- Create [backup configuration](config/backup-todo.yaml) for namespace todo

  ```yaml
  apiVersion: velero.io/v1
  kind: Backup
  metadata:
    name: todo
    labels:
      velero.io/storage-location: default
    namespace: openshift-adp
  spec:
    defaultVolumesToRestic: true
    hooks: {}
    includedNamespaces:
    - todo
    storageLocation: app-backup-1 
    ttl: 720h0m0s
  ```

  Run following command

  ```bash
  oc create -f config/backup-todo.yaml
  ```

- Verify backup status
  
  ```bash
  oc get backup/todo -n openshift-adp -o jsonpath='{.status}'|jq
  ```
  
  Output
  
  ```json
  {
    "completionTimestamp": "2022-08-30T09:50:00Z",
    "expiration": "2022-09-29T09:49:24Z",
    "formatVersion": "1.1.0",
    "phase": "Completed",
    "progress": {
      "itemsBackedUp": 69,
      "totalItems": 69
    },
    "startTimestamp": "2022-08-30T09:49:24Z",
    "version": 1
  }
  ```

  Test with 10GB data

  ```json
  {
    "completionTimestamp": "2022-10-12T12:51:45Z",
    "expiration": "2022-11-11T12:50:18Z",
    "formatVersion": "1.1.0",
    "phase": "Completed",
    "progress": {
      "itemsBackedUp": 89,
      "totalItems": 89
    },
    "startTimestamp": "2022-10-12T12:50:18Z",
    "version": 1
  }
  ```

- Check data in MinIO
  
  ![](images/minio-bucket.png)

### Schedule Backup

- Create [schedule](config/schedule-todo.yaml) for backup namespace todo
  
  ```yaml
  apiVersion: velero.io/v1
  kind: Schedule
  metadata:
    name: todo
    namespace: openshift-adp
  spec:
    defaultVolumesToRestic: true
    schedule: 0 5 * * * #crontab format for schedule backup
    template:
      hooks: {}
      includedNamespaces:
      - todo
      storageLocation: app-backup-1 
      defaultVolumesToRestic: true 
      ttl: 720h0m0s
  ```

  Create schedule backup

  ```bash
  oc create -f config/schedule-todo.yaml
  ```
  
  - Check result after schedule is created. 
  ```bash
  oc get schedule/todo -n openshift-adp -o jsonpath='{.status}'   
  ```
  
  Output
  
  ```json
  {
    "lastBackup": "2022-08-30T13:51:32Z",
    "phase": "Enabled"
  }
  ```

### Restore
  
- Delete deployment and pvc in namespace todo
  
  ```bash
  oc delete deployment/todo-db -n todo
  oc delete pvc todo-db -n todo
  ```

- List backup name and select

  ```bash
  oc get backup -n openshift-adp
  ```
  
  Output
  
  ```bash
  NAME                  AGE
  todo                  3m18s
  todo-20220830135132   3m18s
  todo-20220830140034   3m18s
  todo-20220830141034   3m18s
  todo-20220830142634   18m
  ```

  Or use OpenShift Admin Console

  ![](images/oadp-operator-backup-list.png)

- Edit [restore-todo.yaml](config/restore-todo.yaml) and replace spec.backupName with name from previous step.
  
  ```yaml
  apiVersion: velero.io/v1
  kind: Restore
  metadata:
    name: todo
    namespace: openshift-adp
  spec:
    backupName: <backup name> 
    excludedResources:
    - nodes
    - events
    - events.events.k8s.io
    - backups.velero.io
    - restores.velero.io
    - resticrepositories.velero.io
    - route
    restorePVs: true
  ```
  
  Run following command
  
  ```bash
  oc create -f config/restore-todo.yaml
  ```
  
  Check for restore status
  
  ```bash
  oc get restore/todo -n openshift-adp -o yaml|grep -A8 'status:'
  ```

  Output
  
  ```yaml
  status:
    phase: InProgress
    progress:
      itemsRestored: 47
      totalItems: 47
    startTimestamp: "2022-08-30T14:28:53Z"
  ```
    
  Output when restoring process is completed
  
  ```yaml
  status:
    completionTimestamp: "2022-08-30T14:29:32Z"
    phase: Completed
    progress:
      itemsRestored: 47
      totalItems: 47
    startTimestamp: "2022-08-30T14:28:53Z"
    warnings: 5
  ```

- Verify todo apps.

## Restore from another cluster
- Install OADP operator
- Create secret cloud-credentials to access minio bucket
- Create [DataProtectionApplication](config/DataProtectionApplication.yaml) with s3url point to minio's route
- Create [Restore](config/restore-todo.yaml)

## Minio Client
- Install [Minio Client](https://github.com/minio/mc)
- Configure alias to MinIO with alias name minio
  
  ```bash
  mc alias set minio <URL> <KEY> <SECRET>
  mc alais ls
  ```
- Copy from bucket cluster1 to current directory
  
  ```bash
  mc cp --recursive minio/cluster1 .
  ```

  Output
  
  ```bash
  ...re-todo-results.gz: 19.52 MiB / 19.52 MiB ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????? 2.27 MiB/s 8s
  ```

- Verify data
  
  ```bash
  cluster1
  ????????? oadp
      ????????? backups
      ??????? ????????? todo
      ???????     ????????? todo-csi-volumesnapshotclasses.json.gz
      ???????     ????????? todo-csi-volumesnapshotcontents.json.gz
      ???????     ????????? todo-csi-volumesnapshots.json.gz
      ???????     ????????? todo-logs.gz
      ???????     ????????? todo-podvolumebackups.json.gz
      ???????     ????????? todo-resource-list.json.gz
      ???????     ????????? todo-volumesnapshots.json.gz
      ???????     ????????? todo.tar.gz
      ???????     ????????? velero-backup.json
      ????????? restic
      ??????? ????????? todo
  ```

- Copy from local to minio

  ```bash
  mc cp --recursive cluster1/oadp minio/cluster1
  ```

  Output

  ```bash
  .../restore-todo-results.gz: 19.52 MiB / 19.52 MiB ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????? 4.83 MiB/s 4s
  ```
