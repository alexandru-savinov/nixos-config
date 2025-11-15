# Custom Agents

This file defines specialized AI agents for the NixOS configuration repository. Each agent has domain expertise and should be consulted for specific tasks.

---

## @nix-expert

**Domain**: NixOS configuration, flake management, and Nix language

**Expertise**:
- Nix flake structure and dependencies
- NixOS module system and composition
- Package management and overlays
- Home-manager integration
- Multi-system support (x86_64-linux, aarch64-linux)
- Nix expression language best practices

**Use for**:
- Writing or modifying `flake.nix`
- Creating new NixOS modules in `modules/`
- Adding system packages or services
- Debugging Nix evaluation errors
- Optimizing flake inputs and follows patterns
- Package derivations and overrides

**Example tasks**:
- "Add a new service module for PostgreSQL"
- "Update nixpkgs input to latest stable"
- "Fix flake check errors"
- "Create overlay for custom package"

---

## @deploy-agent

**Domain**: Deployment workflows, CI/CD, and GitOps

**Expertise**:
- GitHub Actions workflows
- Branch protection and PR requirements
- Deployment scripts (deploy.sh, install.sh)
- Remote deployment via `nix run`
- Status checks and CI pipeline optimization
- Git workflow automation

**Use for**:
- Modifying `.github/workflows/`
- Updating deployment scripts in `scripts/`
- Configuring branch protection rules
- Setting up new CI checks or tests
- Troubleshooting GitHub Actions failures
- Automating release processes

**Example tasks**:
- "Add a security scanning workflow"
- "Update deploy.sh to support rollback"
- "Create release automation"
- "Fix CI build failures"

---

## @infra-specialist

**Domain**: Infrastructure, networking, and services

**Expertise**:
- Hetzner Cloud configuration
- Static networking setup (no DHCP)
- Firewall rules and security
- Tailscale VPN and mesh networking
- Service containerization (Docker/Podman)
- Open WebUI and AI gateway services
- SSH hardening and access control

**Use for**:
- Configuring networking in `modules/system/networking.nix`
- Setting up new services in `modules/services/`
- Tailscale integration and serve configuration
- Container orchestration
- Security hardening
- Hardware-specific configuration

**Example tasks**:
- "Configure new Tailscale subnet router"
- "Add firewall rules for new service"
- "Set up Docker registry"
- "Harden SSH configuration"

---

## @ai-gateway-expert

**Domain**: Open WebUI, LLM integration, and authentication

**Expertise**:
- Open WebUI configuration and deployment
- Ollama backend integration
- Tailscale Serve for HTTPS exposure
- tsidp OAuth authentication
- MCP (Model Context Protocol) servers
- AI service orchestration

**Use for**:
- Modifying `modules/services/open-webui.nix`
- Configuring Tailscale Serve for web services
- Setting up OAuth with tsidp
- Managing Ollama models and backends
- MCP server configuration
- AI service security and access control

**Example tasks**:
- "Add new Ollama model configuration"
- "Configure OAuth redirect URIs"
- "Set up model load balancing"
- "Add authentication middleware"

---

## @docs-writer

**Domain**: Documentation, guides, and knowledge management

**Expertise**:
- Technical documentation writing
- README maintenance
- Inline code comments
- Architecture decision records (ADRs)
- Troubleshooting guides
- API documentation

**Use for**:
- Updating `README.md`
- Writing module documentation
- Creating troubleshooting guides
- Documenting new features
- Updating copilot instructions
- Creating user guides

**Example tasks**:
- "Document the new service module"
- "Update README with new deployment method"
- "Create troubleshooting section for networking"
- "Add inline documentation to complex functions"

---

## @security-auditor

**Domain**: Security, secrets management, and compliance

**Expertise**:
- SSH key management
- Secrets and credential handling
- Firewall configuration
- Network security
- Branch protection and code review
- Security scanning (GitGuardian)
- Vulnerability assessment

**Use for**:
- Reviewing security configurations
- Implementing secrets management
- Auditing SSH and access controls
- Analyzing firewall rules
- Evaluating dependency vulnerabilities
- Security hardening recommendations

**Example tasks**:
- "Audit current SSH configuration"
- "Implement sops-nix for secrets"
- "Review firewall rules for security"
- "Check for exposed credentials"

---

## Agent Selection Guidelines

**For configuration changes**: `@nix-expert`
**For deployment/CI**: `@deploy-agent`
**For networking/infrastructure**: `@infra-specialist`
**For AI services**: `@ai-gateway-expert`
**For documentation**: `@docs-writer`
**For security review**: `@security-auditor`

**Multiple agents**: Complex tasks may require collaboration between agents. For example:
- Adding a new service: `@nix-expert` + `@infra-specialist`
- Deploying AI gateway: `@ai-gateway-expert` + `@deploy-agent`
- Security hardening: `@security-auditor` + `@infra-specialist`

---

**Last Updated**: 2025-11-15
