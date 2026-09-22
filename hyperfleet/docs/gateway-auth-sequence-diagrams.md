---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-09-22
---

# Gateway Authentication, TLS and Tenancy: Sequence Diagrams

## Overview

The gateway authentication model has several moving parts (Envoy, Authorino,
ext_authz, TokenReview, the wristband, trusted headers and tenant scoping) that
are hard to hold in your head from prose alone. This document renders the same
flows as Mermaid sequence diagrams: the production `edge+api` path, the legacy
`edge` mode, the fail-closed denials, and the threat model.

It is a companion to
[ADR-0020](../adrs/0020-envoy-authorino-api-gateway.md) and the
[Multi-Tenant Identity and Authorization Design](multi-tenant-identity-authz-design.md).

## State of this document

These diagrams describe the design **as discussed on 16 September 2026**, which
is ahead of the committed ADRs in two ways:

- The **wristband** (Authorino Festival Wristband) and the **`AUTH_MODE`**
  refactor are not yet decision-of-record. They are the pending ADR-0020
  amendment tracked by [HYPERFLEET-1636](https://redhat.atlassian.net/browse/HYPERFLEET-1636).
- The term "wristband" does not appear in any committed document in this
  repository yet.

Treat the flows below as the target design, and ADR-0020 plus the tenancy design
doc as the currently committed state.

## Participants

| Participant | Role |
|-------------|------|
| Client | Human (OIDC JWT) or machine (projected service account token) caller |
| Envoy | Gateway front door. Strips forged headers, calls Authorino, forwards to the API |
| Authorino | Validates credentials, enforces allow-lists and required claims, injects headers, mints the wristband |
| Kubernetes TokenReview | Validates a service account token and returns its subject |
| OIDC IdP | External or mock issuer that signs human tokens |
| hyperfleet-api | Validates the wristband (in `edge+api`), resolves tenancy, scopes the database query |
| Postgres | Stores the `tenancy` JSONB column and evaluates containment (`@>`) |

## 1. `edge+api` happy path (production)

The gateway resolves identity and tenancy for both caller types, the Authorino
mints the wristband, and the API validates that single issuer.

```mermaid
sequenceDiagram
    autonumber
    actor C as Cliente
    participant E as Envoy gateway
    participant A as Authorino
    participant K as Kubernetes TokenReview
    participant I as IdP OIDC
    participant API as hyperfleet-api
    participant DB as Postgres

    C->>E: Authorization: <scheme> <token><br/>+ x-tenant-* forjado
    Note over E: Early header mutation<br/>remove x-tenant-* e x-hyperfleet-*
    E->>A: ext_authz Check (gRPC 50051, server TLS)

    alt Bearer (humano)
        A->>I: valida assinatura JWT
        I-->>A: OK + claims
        Note over A: exige claim de tenant, hf_system=false
    else ServiceAccount (maquina)
        A->>K: TokenReview(token, audience=hyperfleet-api)
        K-->>A: subject
        Note over A: subject na allow-list, hf_system=true
    end

    Note over A: Mint wristband JWT (ES256/RS256)<br/>sub + hf_system + dimensoes de tenant
    A-->>E: allow + x-hyperfleet-system<br/>+ x-hyperfleet-identity + x-tenant-*<br/>Authorization: Bearer <wristband>
    E->>API: forward (8000, server TLS)
    API->>A: fetch JWKS (8083, OIDC)
    A-->>API: JWKS
    Note over API: JWT middleware valida o wristband (issuer unico)
    Note over API: Tenant middleware resolve as dimensoes dos headers
    API->>DB: SELECT ... WHERE tenancy @> caller_map
    DB-->>API: linhas
    API-->>E: resposta com escopo de tenant
    E-->>C: 200
```

## 2. `edge` mode (no wristband)

In `edge` mode the API runs no JWT middleware and trusts the injected headers
unconditionally. The original credential is not swapped for a wristband.

```mermaid
sequenceDiagram
    autonumber
    actor C as Cliente
    participant E as Envoy gateway
    participant A as Authorino
    participant API as hyperfleet-api
    participant DB as Postgres

    C->>E: Authorization: ServiceAccount <token>
    Note over E: Early header mutation (strip)
    E->>A: ext_authz Check
    Note over A: valida credencial + allow-list
    A-->>E: allow + x-hyperfleet-system, x-hyperfleet-identity, x-tenant-*
    E->>API: forward (sem TLS ainda, ver 1635),<br/>sem troca de Authorization
    Note over API: NAO roda JWT middleware<br/>confia nos headers injetados
    API->>DB: SELECT ... WHERE tenancy @> caller_map
    DB-->>API: linhas
    API-->>E: resposta
    E-->>C: 200
```

## 3. Fail-closed denials

Every rejection happens at the gateway; the API is never reached.

```mermaid
sequenceDiagram
    autonumber
    actor C as Cliente
    participant E as Envoy gateway
    participant A as Authorino
    participant K as Kubernetes TokenReview
    participant API as hyperfleet-api

    alt Scheme desconhecido
        C->>E: Authorization: Basic ...
        E->>A: ext_authz Check
        A-->>E: deny
        E-->>C: 401 (nunca chega na API)
    else SA token fora da allow-list
        C->>E: Authorization: ServiceAccount <token>
        E->>A: ext_authz Check
        A->>K: TokenReview
        K-->>A: subject nao listado
        A-->>E: deny
        E-->>C: 401
    else Humano sem a claim de tenant
        C->>E: Authorization: Bearer <oidc jwt>
        E->>A: ext_authz Check
        Note over A: claim obrigatoria ausente
        A-->>E: deny
        E-->>C: 403
    end
    Note over API: em todos os casos a API nunca e alcancada
```

## 4. Threat model as sequences

The four attacks below map one-to-one to the threat table in the crash course.
Green is defended, red is the gap, yellow is the fix, purple is TLS.

```mermaid
sequenceDiagram
    autonumber
    actor M as Pod malicioso
    participant E as Envoy gateway
    participant A as Authorino
    participant API as hyperfleet-api
    participant NP as NetworkPolicy

    rect rgb(232, 245, 233)
    Note over M,API: Ataque 1 - forjar headers passando pelo Envoy
    M->>E: x-tenant-org: vitima + credencial valida
    Note over E: strip ANTES do ext_authz<br/>headers forjados descartados
    E->>A: ext_authz Check
    A-->>E: allow + x-tenant-* reais do caller
    E->>API: headers apenas do Authorino
    end

    rect rgb(255, 235, 238)
    Note over M,API: Ataque 2 - pular o Envoy direto na API
    M->>NP: conexao direta a API
    alt NetworkPolicy aplicada
        NP-->>M: bloqueado
    else sem policy engine (aceita e ignora)
        M->>API: headers forjados, sem credencial
        Note over API: edge: aceita (FALHA)<br/>edge+api: exige wristband -> 401
    end
    end

    rect rgb(255, 248, 225)
    Note over M,API: Ataque 3 - wristband proprio + tenant forjado (o gap)
    M->>A: credencial valida qualquer
    A-->>M: wristband legitimo (sub do atacante)
    M->>API: Authorization: Bearer <wristband><br/>x-tenant-org: vitima + x-hyperfleet-system: true
    Note over API: autenticacao passa,<br/>tenancy = o que ele digitou (GAP)
    Note over API: Fix proposto: resolver tenancy<br/>das claims do wristband, nao dos headers
    end

    rect rgb(237, 231, 246)
    Note over E,API: Ataque 4 - impostor Authorino ou API
    E->>A: ext_authz Check
    A-->>E: certificado nao valida contra a CA
    Note over E: conexao rejeitada (TLS + CA)
    end
```

## Reading notes

- The wristband only appears in flow 1 (`edge+api`). In `edge` mode (flow 2)
  there is no `Authorization` swap, which is exactly where the attack-3 gap
  lives.
- The early header strip in attack 1 is the ordering constraint that tripped up
  the first multitenancy proof of concept: route-level header removal runs after
  ext_authz and would delete the headers Authorino injects.
- Attack 2 is why the second layer exists. A NetworkPolicy on a cluster with no
  policy engine is accepted by the apiserver and silently ignored.
- Attack 3 is the gap recorded as an e2e case on
  [HYPERFLEET-1621](https://redhat.atlassian.net/browse/HYPERFLEET-1621). The
  fix (tenancy from wristband claims) is a separate story under HYPERFLEET-1164,
  not yet created.
- TLS on the in-cluster hops (Envoy to Authorino, Envoy to API) does not
  authenticate the caller. It prevents reading a credential or wristband in
  transit and prevents Envoy from talking to an impostor Authorino or API.

## References

- [ADR-0020: Envoy and Authorino as the API Authentication Gateway](../adrs/0020-envoy-authorino-api-gateway.md)
- [Multi-Tenant Identity and Authorization Design](multi-tenant-identity-authz-design.md)
- [HYPERFLEET-1636: ADR-0020 amendment](https://redhat.atlassian.net/browse/HYPERFLEET-1636)
- [HYPERFLEET-1484: In-app JWT behind the gateway](https://redhat.atlassian.net/browse/HYPERFLEET-1484)
- [HYPERFLEET-1621: e2e runs with the gateway on](https://redhat.atlassian.net/browse/HYPERFLEET-1621)
