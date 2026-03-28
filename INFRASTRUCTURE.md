# Kubernetes Infrastructure

모든 매니페스트는 4-Tier 디렉터리([`0-core/`](0-core/), [`1-data/`](1-data/), [`2-platform/`](2-platform/), [`3-apps/`](3-apps/))에 `${VAR}` 플레이스홀더를 포함한 템플릿으로 작성되며, Flux CD가 `postBuild.substituteFrom`으로 변수를 치환하여 배포한다.

## 매니페스트 생성 파이프라인

```text
git push
  -> Flux CD 감지
  -> tier 디렉터리의 kustomization 빌드
  -> postBuild substituteFrom
  -> Flux가 최종 매니페스트를 클러스터에 적용
```

- **변수 소스(비민감)**: `flux-system` 네임스페이스의 `cluster-config` ConfigMap (CI에서 `.env.config`로 동기화)
- **변수 소스(민감)**: `flux-system` 네임스페이스의 `cluster-secrets` Secret ([Infisical Operator](0-core/flux-system/infisical-secret.yaml)가 동기화)

## 서비스 카탈로그

### 0-core -- 클러스터 기반

| 카테고리   | 서비스                                                                                        |
| :--------- | :-------------------------------------------------------------------------------------------- |
| Networking | Traefik, MetalLB (Helm), cert-manager (Helm), NetworkPolicy                                   |
| Storage    | 공유 PVC (NFS)                                                                                |
| Compute    | NVIDIA Device Plugin                                                                          |
| Flux       | GitRepository, Kustomization (4-Tier), HelmRepository, InfisicalSecret, ImageUpdateAutomation |

### 1-data -- 데이터베이스

PG + pgvector, Redis

### 2-platform -- 플랫폼 공통 서비스

| 카테고리      | 서비스                                                                                         |
| :------------ | :--------------------------------------------------------------------------------------------- |
| Security      | Pocket ID (OIDC IdP), OAuth2-Proxy (ForwardAuth)                                               |
| Networking    | AdGuard (DNS), CoreDNS, Cloudflared (Tunnel)                                                   |
| Observability | Prometheus, Grafana, Blackbox Exporter, kube-state-metrics, Node Exporter, NVIDIA GPU Exporter |
| Backup        | Velero (Helm), PostgreSQL Backup/Restore-test, platform-rclone (B2 sync)                       |
| CI            | Gitea, Act Runner (amd64/arm64)                                                                |
| Storage       | Samba                                                                                          |
| Logging       | Loki + Promtail (Helm)                                                                         |
| Secrets       | Infisical (Helm), Secrets Operator (Helm)                                                      |

### 3-apps -- 엔드유저 워크로드

`3-apps/` 디렉터리에 카테고리별로 앱을 추가한다.

Sample:

| 카테고리 | 서비스                                 |
| :------- | :------------------------------------- |
| AI       | Ollama, Open-WebUI                     |
| IoT      | Home Assistant, Mosquitto, Zigbee2MQTT |

## 네트워킹 및 Ingress 라우팅

- **Flannel**: VXLAN으로 노드 간 통신
- **Ingress**: Traefik이 `https://*.${DOMAIN_LAN}` 도메인을 라우팅한다.
- **LoadBalancer**: MetalLB L2 모드로 고정 IP 할당.
- **ForwardAuth**: 자체 인증이 없거나 SSO를 활용할 서비스에 OAuth2-Proxy ForwardAuth 미들웨어를 적용한다.

## Kustomize 컴포넌트

| 컴포넌트                                                       | 대상       | 동작                                                                     |
| :------------------------------------------------------------- | :--------- | :----------------------------------------------------------------------- |
| [`oauth-ingress`](components/oauth-ingress/)                   | Ingress    | `auth` 라벨 없는 Ingress에 OAuth2-Proxy ForwardAuth 주입                 |
| [`revision-history-limit`](components/revision-history-limit/) | Deployment | 전체 Deployment에 `revisionHistoryLimit: 2` 적용                         |
| [`strategy-recreate`](components/strategy-recreate/)           | Deployment | `strategy-rolling` 라벨 없는 Deployment에 Recreate 적용                  |
| [`gpu-workload`](components/gpu-workload/)                     | Deployment | `gpu` 라벨 Deployment에 runtimeClassName, nodeSelector, tolerations 주입 |

## 배포 순서 (4-Tier dependsOn)

| Tier | Kustomization      | 경로           | 의존               |
| :--- | :----------------- | :------------- | :----------------- |
| 0    | `homelab-core`     | `./0-core`     | 없음               |
| 1    | `homelab-data`     | `./1-data`     | `homelab-core`     |
| 2    | `homelab-platform` | `./2-platform` | `homelab-data`     |
| 3    | `homelab-apps`     | `./3-apps`     | `homelab-platform` |

## 스토리지 및 노드 스케줄링

- **스토리지**:
  - `nfs-client`: NFS 동적 프로비저닝
  - `local-path`: 노드 로컬 디스크 직접 접근. DB, SQLite 앱, GPU 워크로드(고속 I/O)에 사용

- **스케줄링**:
  - `NODE_IOT`: IoT 디바이스 접근이 필요한 서비스
  - `NODE_STORAGE`: DB, SQLite 앱 등 `local-path` 볼륨 사용 서비스 고정
  - `NODE_COMPUTE`: GPU 워크로드 + CI. `local-path`로 모델/캐시 저장. `node-role=compute:NoSchedule` Taint
  - **Floating**: NFS 접근 가능한 아무 노드

> GPU는 Time-slicing으로 물리 GPU를 복수 가상 슬롯으로 공유함

## Helm 차트

Flux HelmRelease로 선언적 관리된다. values는 HelmRelease에 inline 정의

| 차트                                         | 네임스페이스   | HelmRelease 위치                                                 |
| :------------------------------------------- | :------------- | :--------------------------------------------------------------- |
| `jetstack/cert-manager`                      | cert-manager   | [`0-core/helm-releases.yaml`](0-core/helm-releases.yaml)         |
| `metallb/metallb`                            | metallb-system | [`0-core/helm-releases.yaml`](0-core/helm-releases.yaml)         |
| `nfs-subdir/nfs-subdir-external-provisioner` | default        | [`0-core/helm-releases.yaml`](0-core/helm-releases.yaml)         |
| `grafana/loki`                               | default        | [`2-platform/helm-releases.yaml`](2-platform/helm-releases.yaml) |
| `vmware-tanzu/velero`                        | velero         | [`2-platform/helm-releases.yaml`](2-platform/helm-releases.yaml) |
| `infisical/infisical-standalone`             | infisical      | [`2-platform/helm-releases.yaml`](2-platform/helm-releases.yaml) |
| `infisical/secrets-operator`                 | infisical      | [`2-platform/helm-releases.yaml`](2-platform/helm-releases.yaml) |

MetalLB IP 풀 설정([`metallb-config.yaml`](0-core/networking/metallb-config.yaml))과 Traefik HelmChartConfig([`traefik.yaml`](0-core/networking/traefik.yaml))는 `0-core/networking/`에서 kustomize로 관리한다.

> 각 LB IP는 `.env.config`의 `LB_*` 값으로 설정됨

## 인증 아키텍처

모든 Ingress 노출 서비스는 Pocket ID + OAuth2-Proxy를 통해 인증된다.

| 인증 패턴                | 적용 방식                                                    | 예시                |
| :----------------------- | :----------------------------------------------------------- | :------------------ |
| **ForwardAuth**          | `components/oauth-ingress/`가 자동 주입. 앱 수정 불필요      | 대부분의 서비스     |
| **OIDC**                 | 앱이 Pocket ID에 직접 OIDC 연동. Ingress에 `auth: self` 라벨 | Grafana, Open-WebUI |
| **자체 인증 유지**       | 앱 기능에 인증이 묶여있는 경우. Ingress에 `auth: self` 라벨  | Home Assistant      |
| **인증 없음 (LAN 전용)** | hostNetwork 또는 내부 전용 서비스                            | MQTT 브로커         |

## 백업 및 복원

### Velero

Velero가 매일 03:00에 K8s 리소스와 어노테이션이 적용된 PVC 데이터를 B2에 백업하고 7일간 보존한다.

```yaml
# 값은 `volumes[].name`과 일치해야 한다. (PVC 이름이 아님)
annotations:
  backup.velero.io/backup-volumes: <VOLUME_NAME>
```

**복원:**

```bash
velero backup get
velero restore create --from-backup <BACKUP_NAME>
```

### pg_dump (NFS)

매일 01:00에 템플릿을 제외한 모든 데이터베이스를 논리 덤프한다.
이후 `shared-misc` PVC의 `backups/`에 저장하고 7일간 보존한다.

> 덤프는 04:00에 rclone으로 B2에 증분 동기화한다.

### pg_dump 복원 테스트

매주 일요일 05:00에 최신 덤프를 임시 DB에 복원하여 무결성을 검증한다.

### 서비스 가용성 모니터링

Prometheus Blackbox Exporter가 내부 Service 엔드포인트를 HTTP/TCP probe한다.

### Loki 로그

Loki + Promtail로 전체 노드의 컨테이너 로그를 수집하고 7일간 보존한다.
