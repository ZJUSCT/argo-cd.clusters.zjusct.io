# argo-cd.clusters.zjusct.io

This repository is the Kubernetes cluster GitOps configuration center for [Zhejiang University Supercomputing Team (ZJUSCT)](https://www.zjusct.io), implementing declarative management and continuous synchronization of cluster state. **This project is an exploration and practice of a new paradigm for AI-assisted Operations (AIOps).**

## Design Philosophy

The design philosophy of this project can be summarized in one sentence: **Let AI take over the time-consuming information processing work**, allowing human engineers to focus on system logic design and architectural decisions.

The core challenge of traditional operations work stems from the **inherent complexity** accumulated in continuously evolving systems, and the resulting **high cost of information transmission and processing**. Information such as configuration intent, service dependencies, and historical decision context is often buried in command history, temporary environment variables, or incomplete documentation, making maintenance, troubleshooting, and knowledge transfer extremely difficult, and system state fragile and ambiguous.

We believe that AI technologies represented by Large Language Models (LLMs) provide new tools to change this situation. The key is to **clearly define the different roles of AI and humans in operations work**:

- **AI should serve as a powerful information processor and aggregator**: LLMs excel at quickly retrieving, extracting, and summarizing information from massive, multi-source text (code, configuration, logs, documentation). This means they can efficiently replace humans in information gathering, organization, and preliminary attribution, freeing operations personnel from tedious "information archaeology."
- **Humans must always maintain control over system logic thinking and design authority**: We must clearly recognize that **current probability-statistics-based LLMs do not possess true system logic capabilities**. They cannot understand the deep intent of architectural design, cannot make responsible trade-offs in ambiguous areas, and cannot perform truly creative abstract design. For core questions requiring logical reasoning, value judgment, and creative thinking—such as "How should system boundaries be defined," "Is the service abstraction reasonable," and "What are the long-term impacts of changes"—the role of human engineers is irreplaceable.

Therefore, the paradigm we explore is: **Humans are responsible for defining system logic and architecture (What & Why), AI assists humans in efficiently processing implementation and state information (How & Current Status), with both parties working collaboratively within clear boundaries.**

This repository is the initial practical vehicle for this philosophy. We attempt to completely codify and version the expected state of the cluster through the GitOps methodology, aiming to **"make Git the single source of truth for system state."** This practice aims to **reduce** the information gap between the runtime environment and declarative code, thereby providing AI tools with a clear, traceable analysis foundation, enabling them to more reliably assist humans in understanding system state, evaluating changes, and locating problems.

Within this framework, AI will be encouraged to serve as the primary daily operator of this repository, completing cluster operations work under the logical framework and supervision set by humans.

## Documentation

- Language: The operations team primarily communicates in Chinese and is mainly responsible for writing Chinese documentation ending with `.zh-cn.md`. AI is responsible for translating the content of `.zh-cn.md` files into corresponding `.md` files for reference by the international open source community, etc.
- `AGENTS.zh-cn.md`: Reference [AGENTS.md](https://agents.md/). This contains overall constraints and guiding principles for AI, clarifying AI's role positioning, capability boundaries, and behavioral norms in this project.
- Content: Avoid piling up documentation; for example, self-evident facts in service Git configuration files should not be restated in documentation. Documentation should only record **information that is not easily obtained directly from code but is critical for understanding system state and design decisions**, such as background and trade-offs of design decisions, explanations of complex dependency relationships between services, context of historical changes, etc.

## Constraints

This Git repository enforces the following constraints through pre-commit hooks and CI pipelines:

- Folders under `dev/` and `production/` directories cannot have duplicate names to avoid naming conflicts in ApplicationSet templates.
- All Applications must pass rendering tests with kustomize build or similar tools before pushing to ensure valid Kubernetes resource manifests can be generated.
- Critical credentials are not allowed to appear in plain text in code; encryption tools (such as Sealed Secrets) must be used for encryption before storage.

## Repository Layout

### Top-level Directories

- **`production/`** — Applications already stably deployed in the production environment
- **`dev/`** — For development/testing applications

The `dev/` and `production/` directories are each automatically managed by an Argo CD ApplicationSet, whose core mechanism is to map each subdirectory to an Application through a Git generator. See specific configuration in [production/argo-cd/apps.yaml](production/argo-cd/apps.yaml), with the key rules as follows:

```yaml
generators:
    - git:
        directories:
        - path: production/*
template:
    metadata:
    name: '{{path.basename}}'
    namespace: '{{path.basename}}'
    spec:
    source:
        path: '{{path}}'
    destination:
        namespace: '{{path.basename}}'
```

Therefore, each folder will be treated as an Application, using the folder name as the name and target namespace.

- **`scripts/`** — Auxiliary scripts, such as validation and deployment tool scripts

### Application Layout

Each application (`production/*` or `dev/*`) follows this pattern:

```text
namespace-name/
├── .gitignore
├── kustomization.yaml          # Main Kustomize configuration
├── values/                      # Helm chart value overrides
│   ├── chart1.yaml
│   └── chart2.yaml
├── resources/                   # Custom Kubernetes resources
│   ├── namespace.yaml
│   ├── configmaps.yaml
│   └── *-sealedsecret.yaml     # Encrypted secrets
└── charts/                      # Local Helm charts (if needed)
    └── chart-name/
```

- If there are many services in a namespace, you can create subdirectories (such as `values` and `resources`) under the namespace folder to organize Helm chart value overrides and Kubernetes resource definitions.
- `.gitignore` is generally used to exclude Helm Charts automatically pulled by `kustomize` builds, which do not need to be version controlled. The exception is some custom Helm Charts that may need to be version controlled, for example:

    ```text
    charts/*
    !charts/freeipa
    ```

## K8S Cluster Status and Deployment Guide

### Storage

Existing StorageClasses and their applicable scenarios:

- `openebs-hostpath`: OpenEBS-based local storage, suitable for applications with high read/write performance requirements such as databases
- `ceph-block`: Suitable for applications requiring high availability and elastic scaling
- `cephfs`: Suitable for applications requiring shared access

### Network

CNI plugin: cilium, with Hubble enabled for network observability

Ingress:

- IngressClasses: `nginx`, although widely used, it has entered maintenance status, and it is recommended to use the newer Gateway API
- Gateway: `envoy-gateway`, listening on 80 (HTTP), 443 (HTTPS, with TLS wildcard certificate configured), and 444 (TLS Passthrough, suitable for applications that need to directly expose TLS services)

### Application Deployment

Our K8S application deployment method has gone through four iterations:

- [kubectl](https://kubernetes.io/docs/reference/kubectl/): Manual resource management, lacking version control and automation
- [Helm](https://helm.sh/): Introduced Helm charts, improving templating and parameterization capabilities, but difficult to manage resources outside templates
- [Kustomize](https://kustomize.io/): Compensates for Helm's shortcomings, enabling declarative management of all K8S resources
- [Argo CD](https://argo-cd.readthedocs.io/): Implements the GitOps pattern, automatically synchronizing Git repository and cluster state
