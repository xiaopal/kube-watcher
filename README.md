kube-watcher script
===
kubernetes operator by kubectl + shell script


```
dumb-init ./kube-watcher.sh --all-namespaces configmaps -l kube-watcher/enabled=1

dumb-init ./kube-watcher.sh --namespace 'default' configmaps --exec-create 'echo CREATE;jq . $TARGET' --exec-update 'echo UPDATE;jq . $TARGET' --exec-delete 'echo DELETE;jq . $TARGET'

docker run ---it --rm xiaopal/kube-watcher --namespace 'default' configmaps --exec-create 'echo CREATE;jq . $TARGET' --exec-update 'echo UPDATE;jq . $TARGET' --exec-delete 'echo DELETE;jq . $TARGET'
```
