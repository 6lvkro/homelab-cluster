# Homelab Cluster

[![Kubernetes](https://img.shields.io/badge/kubernetes-k3s-blue?style=flat-square&logo=kubernetes)](https://k3s.io/)
[![FluxCD](https://img.shields.io/badge/fluxcd-GitOps-blue?style=flat-square&logo=flux)](https://fluxcd.io/)

**k3s 기반 쿠버네티스 홈랩 인프라 레포지토리**
선언적 관리와 Flux CD를 통한 GitOps

> ARM SBC 2대 (control-plane/IoT, storage) + x86_64 데스크탑 1대 (NVIDIA GPU/CI) 구성 기준 템플릿.
> 노드 수와 역할은 `.env.config`에서 조정 가능하며, 하나의 노드가 여러 역할을 겸할 수 있다.
>
> 이 레포는 로컬 Gitea 서버에서 CI 워크플로우([`mirror-public`](.gitea/workflows/mirror-public.yaml))를 통해 개인 설정을 제외한 상태로 미러링된다.

---

## 클러스터 구조

| 역할              | 환경 변수      | 워크로드 예시                                                      |
| :---------------- | :------------- | :----------------------------------------------------------------- |
| **Control Plane** | `NODE_MASTER`  | k3s server                                                         |
| **IoT**           | `NODE_IOT`     | Home Assistant, Mosquitto, Zigbee2MQTT                             |
| **Storage**       | `NODE_STORAGE` | NFS, DB, SQLite 앱, Samba                                          |
| **Compute**       | `NODE_COMPUTE` | GPU 워크로드 (Ollama 등), CI (Act Runner), 그 외 고속 I/O 워크로드 |

## 디렉터리 구조 (4-Tier GitOps)

```text
0-core/                # Tier 0: 클러스터 코어
├── networking/        # Traefik, MetalLB, cert-manager, NetworkPolicy
├── storage/           # 공유 PVC (NFS)
├── compute/           # NVIDIA device plugin
├── flux-system/       # GitRepository, Kustomization, HelmRepository, ImageAutomation
└── helm-releases.yaml # cert-manager, MetalLB, NFS provisioner

1-data/                # Tier 1: 데이터베이스 (PG + pgvector, Redis)

2-platform/            # Tier 2: 플랫폼 공통 서비스
├── security/          # Pocket ID, OAuth2-Proxy
├── networking/        # AdGuard, CoreDNS, Cloudflared
├── observability/     # Prometheus, Grafana, Exporters
├── backup/            # Velero, PostgreSQL 백업
├── ci/                # Gitea, Act Runner
├── storage/           # Samba
└── helm-releases.yaml # Loki, Velero, Infisical, Secrets Operator

3-apps/                # Tier 3: End User 워크로드
├── ai/                # e.g., Ollama, Open-WebUI
├── iot/               # e.g., Home Assistant, Zigbee2MQTT, Mosquitto
└── ...                # 카테고리별 앱 추가

components/            # Kustomize 공통 컴포넌트
.env.config            # 비민감 환경 변수
.env.example           # 환경 변수 템플릿
```

## 부팅 순서

```text
core -> data -> platform -> apps
```

[Flux Kustomization](0-core/flux-system/kustomizations.yaml)에서 계층 간 직렬 의존성을 보장한다.

---

## 참고

- 초기 구축 절차: [BOOTSTRAP.md](BOOTSTRAP.md)
- 매니페스트 스펙: [INFRASTRUCTURE.md](INFRASTRUCTURE.md)
