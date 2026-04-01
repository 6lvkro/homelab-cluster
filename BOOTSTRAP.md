# 클러스터 부트스트랩 가이드

k3s 클러스터 초기 구축 절차를 설명하는 문서

## 선행 요구사항

- 리눅스 서버 1대 이상 (ARM64/x86_64)
- GPU 노드 (옵션 - AI 워크로드용)

## 필수 도구

| 도구      | 용도                             |
| --------- | -------------------------------- |
| `kubectl` | 클러스터 제어 (`kustomize` 내장) |
| `flux`    | Flux CD CLI                      |

### 설치

```bash
# kubectl
ARCH=$(dpkg --print-architecture)
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
sudo install kubectl /usr/local/bin/

# flux CLI
curl -s https://fluxcd.io/install.sh | sudo bash
```

## 1. 환경 변수 설정

비민감 설정과 시크릿은 분리되어 관리된다.

### 비민감 설정 (.env.config)

IP, 도메인, 서브도메인, 경로 등 인프라 설정. git에 커밋된다.
Flux `postBuild.substituteFrom`에서 ConfigMap으로 참조된다.

### 시크릿 (Infisical)

비밀번호, API 키, 토큰 등 민감 값은 Infisical에서 관리한다.
5단계에서 초기 설정 후 Web UI에서 등록한다.
Flux `postBuild.substituteFrom`에서 Secret으로 참조된다.

## 2. k3s 노드 설치

### 2-1. Server (control-plane 노드)

마스터 노드에 k3s config 작성:

```bash
sudo mkdir -p /etc/rancher/k3s
sudo cat > /etc/rancher/k3s/config.yaml << EOF
node-name: "<NODE_MASTER>"
disable:
  - servicelb
flannel-backend: vxlan
EOF

curl -sfL https://get.k3s.io | sh -
```

### 2-2. Agent (워커 노드)

마스터 노드에서 토큰 확인:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

각 워커 노드에서 config 작성 후 설치:

```bash
sudo mkdir -p /etc/rancher/k3s
sudo cat > /etc/rancher/k3s/config.yaml << EOF
node-name: "<NODE_NAME>"
EOF

curl -sfL https://get.k3s.io | \
  K3S_URL=https://<NODE_MASTER_IP>:6443 \
  K3S_TOKEN=<TOKEN> sh -
```

GPU(compute) 노드에만 taint를 추가한다. 일반 워크로드가 스케줄되지 않도록 격리:

```bash
# GPU 노드의 /etc/rancher/k3s/config.yaml에 추가
node-taint:
  - "node-role=compute:NoSchedule"
```

## 3. 추가 인프라 설정

### 3-1. NFS 서버 구성

```bash
sudo apt install nfs-kernel-server
sudo mkdir -p <PATH_NFS>

# /etc/exports에 추가
echo "<PATH_NFS> <LAN_SUBNET>(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
sudo exportfs -ra
```

### 3-2. NVIDIA CDI 설정 (옵션)

선행: [NVIDIA Container Toolkit 설치](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

k3s-agent 시작 전에 CDI spec을 생성하여 Device Plugin이 첫 기동부터 GPU를 인식하도록 한다.
CDI spec 없이 k3s-agent가 시작되면 GPU allocatable이 0으로 보고되어 GPU Pod가 Pending 상태에 빠진다.

```bash
sudo tee /etc/systemd/system/k3s-gpu-init.service > /dev/null << 'EOF'
[Unit]
Description=Regenerate NVIDIA CDI spec before k3s-agent
After=nvidia-persistenced.service
Before=k3s-agent.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

[Install]
WantedBy=k3s-agent.service
EOF

sudo systemctl daemon-reload
sudo systemctl reenable k3s-gpu-init
```

### 3-3. 레지스트리 인증

Gitea 컨테이너 레지스트리 사용 시 각 노드에 registries.yaml 배치:

```bash
sudo cat > /etc/rancher/k3s/registries.yaml << EOF
mirrors:
  <SUB_GITEA>.<DOMAIN_LAN>:
    endpoint:
      - "https://<SUB_GITEA>.<DOMAIN_LAN>"
configs:
  "<SUB_GITEA>.<DOMAIN_LAN>":
    auth:
      username: <DEFAULT_USERNAME>
      password: <GITEA_TOKEN>
    tls:
      insecure_skip_verify: true
EOF

# 에이전트의 경우 k3s-agent
sudo systemctl restart k3s
```

## 4. Infisical 시크릿

Helm 차트는 Flux HelmRelease로 선언적 관리된다. ([`0-core/helm-releases.yaml`](0-core/helm-releases.yaml), [`2-platform/helm-releases.yaml`](2-platform/helm-releases.yaml))
단, Infisical은 자체 DB 접속 정보가 필요하므로 부트스트랩 시크릿만 수동 생성한다.

```bash
kubectl create namespace infisical
kubectl create secret generic infisical-secrets -n infisical \
  --from-literal=DB_CONNECTION_URI="postgresql://infisical:infisical@postgres.default.svc:5432/infisical" \
  --from-literal=REDIS_URL="redis://redis.default.svc:6379/1" \
  --from-literal=AUTH_SECRET="$(openssl rand -base64 32)" \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -hex 16)" \
  --from-literal=SITE_URL="https://<SUB_INFISICAL>.<DOMAIN_LAN>"
```

> DB 비밀번호 `infisical`은 [`init-databases.sh`](1-data/postgres/init-databases.sh)의 `DB_PASSWORD_INFISICAL`과 일치해야 한다.
> 변경 시 양쪽 모두 업데이트 필요.

## 5. Infisical 초기 설정

### 5-1. 프로젝트 생성

1. `https://<SUB_INFISICAL>.<DOMAIN_LAN>`에 접속하여 관리자 계정을 생성
2. Organization 생성 (또는 기본 Admin Org 사용)
3. 프로젝트 생성 (예: `homelab`)
4. Environment: `dev` (기본값)

### 5-2. 시크릿 등록

프로젝트에 시크릿을 등록한다:

| 폴더 예시       | 시크릿                                                                                                          |
| :-------------- | :-------------------------------------------------------------------------------------------------------------- |
| `/`             | `DEFAULT_PASSWORD`                                                                                              |
| `/postgres`     | `DB_PASSWORD_POSTGRES`, `DB_PASSWORD_GRAFANA`, `DB_PASSWORD_OPENWEBUI`, `DB_PASSWORD_INFISICAL`                 |
| `/gitea`        | `GITEA_TOKEN`, `GITEA_RUNNER_REGISTRATION_TOKEN`                                                                |
| `/cloudflare`   | `CLOUDFLARE_TOKEN`                                                                                              |
| `/b2`           | `B2_KEY_ID`, `B2_APPLICATION_KEY`                                                                               |
| `/pocket-id`    | `POCKET_ID_ENCRYPTION_KEY`, `POCKET_ID_OIDC_GRAFANA`, `POCKET_ID_OIDC_OPENWEBUI`, `POCKET_ID_OIDC_OAUTH2_PROXY` |
| `/oauth2-proxy` | `OAUTH2_PROXY_COOKIE_SECRET`                                                                                    |

> 루트 하위 폴더를 flat하게 동기화하므로 폴더 구조는 UI상 정리 편의용으로만 사용된다.

### 5-3. Machine Identity 생성

1. Organization Settings > Identities > **Create Identity** (`k8s-operator`)
2. Authentication > **Universal Auth** 추가
3. **Client Secret** 생성 > Client ID / Client Secret 기록
4. 프로젝트 > Settings > Access Control > Machine Identities > `k8s-operator`를 **Member**로 추가

### 5-4. K8s Operator 인증 설정

```bash
kubectl create secret generic infisical-machine-identity \
  --from-literal=clientId="<CLIENT_ID>" \
  --from-literal=clientSecret="<CLIENT_SECRET>"
```

## 6. Flux CD 설치 및 연동

> PostgreSQL 초기화: Flux가 매니페스트를 배포하면 PostgreSQL 최초 기동 시 [`init-databases.sh`](1-data/postgres/init-databases.sh)가 실행되어 서비스별 DB/유저를 생성한다.

### 6-1. Flux 부트스트랩

```bash
flux install

# Git 인증 Secret (Gitea 배포 전이지만, Flux가 reconcile 시 자동 재시도)
flux create secret git flux-git-auth \
  --url=http://gitea.default.svc:3000 \
  --username=<USERNAME> \
  --password=<GITEA_TOKEN>
```

### 6-2. 변수 치환 소스 생성

```bash
# ConfigMap -- .env.config의 비민감 값
kubectl create configmap cluster-config -n flux-system \
  --from-env-file=.env.config

# Secret -- Infisical 동기화 후 생성되는 cluster-secrets
# (InfisicalSecret CRD가 자동으로 flux-system/cluster-secrets를 동기화)
```

> 초기 생성 이후 `.env.config` 변경은 CI 워크플로우로 자동화 한다. ([`sync-config.yaml`](0-core/flux-system/sync-config.yaml))
> CI에 필요한 시크릿: Gitea 레포 > Settings > Actions > Secrets > `KUBECONFIG_B64` (base64 kubeconfig)

### 6-3. CA 인증서 추출

cert-manager가 배포되면 자체 CA를 발급한다.

```bash
# cert-manager 배포 대기
kubectl wait --for=condition=available deploy/cert-manager -n cert-manager --timeout=300s

kubectl get secret root-ca-key-pair -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
```

### 6-4. Flux Kustomization 적용

GitRepository, 4-Tier Kustomization, InfisicalSecret은 Git에 선언되어 있다 ([`0-core/flux-system/`](0-core/flux-system/)).
Flux가 자체 리소스를 관리하려면 최초 1회 수동 적용이 필요하다:

```bash
kubectl apply -f 0-core/flux-system/git-source.yaml
kubectl apply -f 0-core/flux-system/kustomizations.yaml
kubectl apply -f 0-core/flux-system/infisical-secret.yaml
```

> 이후 변경은 Git push만으로 Flux가 자동 reconcile한다.

### 6-5. Image Automation 설정

```bash
# ImageRepository/ImagePolicy는 0-core/flux-system/image-policies-*.yaml에서 중앙 관리

# 비공개 레지스트리 인증
kubectl create secret docker-registry gitea-registry -n flux-system \
  --docker-server=https://<SUB_GITEA>.<DOMAIN_LAN> \
  --docker-username=<USERNAME> \
  --docker-password=<GITEA_TOKEN>

# 비공개 레지스트리 CA 인증서
kubectl create secret generic gitea-ca-cert -n flux-system \
  --from-file=ca.crt=homelab-ca.crt
```

## 배포 후 설정

아래 단계들은 Flux가 매니페스트를 배포한 뒤 진행한다.

### 7. CA 인증서 신뢰 등록

6-3에서 추출한 CA를 클라이언트 기기에 등록해야 HTTPS 경고 없이 접근할 수 있다.

```bash
# Linux
sudo cp homelab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
```

> macOS: `security add-trusted-cert`, Windows: `certutil -addstore "ROOT"`, 모바일: 프로파일/인증서 설정에서 설치.
> Firefox는 OS 인증서 저장소를 사용하지 않으므로 별도로 가져오기 필요.

### 8. DNS 및 네트워크

- 라우터 DNS 서버를 `.env.config`의 `LB_ADGUARD_IP`로 설정
- AdGuard DNS rewrite로 `*.<DOMAIN_LAN>` 와일드카드를 Traefik IP로 해석
- 개별 서비스 접근: `https://<SUB_DOMAIN>.<DOMAIN_LAN>`

### 9. OIDC 설정 (Pocket ID)

Pocket ID 관리자 UI(`https://<SUB_POCKET_ID>.<DOMAIN_LAN>`)에서 각 서비스의 OIDC 클라이언트를 등록한다.
OIDC 환경변수가 선언된 서비스는 자동 설정되며, 클라이언트별로 사용자 접근 권한을 부여해야 한다.

#### Gitea OIDC

Gitea는 CLI로 OAuth2 source를 등록한다.

```bash
kubectl exec deploy/gitea -- su -c \
  "gitea admin auth add-oauth \
    --name pocket-id \
    --provider openidConnect \
    --key <CLIENT_ID> \
    --secret <CLIENT_SECRET> \
    --auto-discover-url https://<SUB_POCKET_ID>.<DOMAIN_LAN>/.well-known/openid-configuration" git
```

### 10. CI 부트스트랩 (Act Runner)

초기 배포 시 순서 의존성:

1. **Act Runner 등록 토큰**: Gitea Admin UI에서 발급 -> Infisical에 등록
2. **커스텀 이미지 빌드**: Runner가 등록된 후 CI가 실행되어야 이미지가 생성됨

```bash
# 1) Flux가 Gitea를 배포할 때까지 대기
kubectl wait --for=condition=available deploy/gitea

# 2) Gitea Admin UI에서 runner 등록 토큰 발급
#    https://<SUB_GITEA>.<DOMAIN_LAN> -> Site Administration -> Actions -> Runners -> Create

# 3) Infisical에 runner 토큰 등록
#    Infisical 프로젝트 > /gitea > GITEA_RUNNER_REGISTRATION_TOKEN 값 업데이트
#    Flux가 Secret 동기화 -> Runner Pod 재시작

# 4) 커스텀 이미지가 필요한 서비스는 CI 빌드 완료까지 ImagePullBackOff 상태
#    CI 완료 후 자동 복구
```
