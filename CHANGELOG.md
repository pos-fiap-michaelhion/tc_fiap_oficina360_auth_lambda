# Changelog

Todas as alterações relevantes deste projeto serão documentadas neste arquivo.

O formato segue o padrão **Keep a Changelog** e o projeto utiliza **Versionamento Semântico** no formato `MAJOR.MINOR.PATCH`.

## [Unreleased]

Nenhuma alteração não publicada no momento.

## [1.0.0] - 2026-11-02

Primeira versão estável da função serverless de autenticação da Oficina360 para a Fase 3 do Tech Challenge.

### Added

- Função AWS Lambda em Java para autenticação da Oficina360.
- Integração HTTP por Amazon API Gateway e AWS SAM.
- Classe `Handler` como ponto de entrada da função.
- Modelos `AuthRequest` e `AuthResponse` para entrada e saída da API.
- Validação de documento por `DocumentValidator`.
- Consulta de cliente PostgreSQL por `UserRepository`.
- Modelo de domínio `User`.
- Emissão de tokens JWT por `JwtService`.
- Configuração do issuer e da expiração do JWT.
- Driver JDBC do PostgreSQL.
- Serialização e desserialização JSON com Jackson.
- Template de infraestrutura serverless em `template.yaml`.
- Build e empacotamento com Maven e AWS SAM.
- Testes unitários de validação de documento.
- Testes unitários do serviço JWT.
- Relatório de cobertura com JaCoCo.
- Análise de dependências com OWASP Dependency-Check.
- Pipeline de build e deploy em `.github/workflows/sam.yml`.
- Pipeline de qualidade em `.github/workflows/sonar.yml`.
- Pipeline de testes em `.github/workflows/teste.yml`.
- Atualização automatizada de dependências com Dependabot.
- Documentação de execução local em `docs/rodar-local.md`.
- Collection do Postman para autenticação local e pelo Kong.
- README com propósito, tecnologias, arquitetura, execução, deploy e contrato da API.

### Changed

- Padronização da autenticação para acesso por meio do Kong Gateway.
- Definição da rota pública `/auth/auth` na plataforma.
- Separação explícita entre autenticação serverless e API principal.
- Configuração do JWT por variáveis de ambiente.
- Padronização do fluxo de build, testes, análise e deploy.

### Fixed

- Compatibilidade entre o issuer emitido pela Lambda e o issuer validado pela API principal.
- Documentação do fluxo correto entre Kong, Amazon API Gateway e Lambda.
- Documentação da diferença entre a rota local `/auth` e a rota pública `/auth/auth`.
- Orientação para não versionar `.aws-sam/`, `target/`, `.idea/` e `.env`.

### Security

- Uso de Secret para a chave de assinatura do JWT.
- Expiração configurável para os tokens emitidos.
- Validação do documento antes da consulta e emissão do token.
- Consulta da existência e situação do cliente antes da autenticação.
- Uso de GitHub Secrets para credenciais AWS e do banco.
- Proteção da branch `main` contra commits diretos.
- Uso de Pull Requests e checks automatizados.
- Dependabot habilitado para atualização de dependências.
- OWASP Dependency-Check incluído no processo de qualidade.
- Orientação para não registrar documentos, tokens ou credenciais nos logs.

## Política de versionamento

O projeto utiliza:

```text
vMAJOR.MINOR.PATCH
```

- **MAJOR:** alteração incompatível no contrato, nas claims ou na validação do JWT.
- **MINOR:** nova funcionalidade compatível, claim adicional ou novo fluxo de autenticação.
- **PATCH:** correção compatível no código, template, pipeline, teste ou documentação.

Exemplos:

```text
v1.0.0    primeira versão estável
v1.1.0    nova funcionalidade compatível
v1.1.1    correção compatível
v2.0.0    alteração incompatível no contrato
```

## Processo de release

1. Registrar as próximas mudanças em `Unreleased`.
2. Abrir Pull Request da branch de release para `main`.
3. Aguardar testes, cobertura, segurança e qualidade.
4. Transformar `Unreleased` em uma versão datada.
5. Integrar o Pull Request na branch `main`.
6. Criar uma tag anotada.
7. Criar a GitHub Release.
8. Recriar a seção `Unreleased`.

### Criar a primeira tag

```bash
git checkout main
git pull origin main
git tag -a v1.0.0 -m "Oficina360 Auth Lambda v1.0.0"
git push origin v1.0.0
```

### Consultar as versões

```bash
git tag --list --sort=-version:refname
git show v1.0.0
```

### Comparar a versão estável com o estado atual

```bash
git diff v1.0.0..HEAD
```

## Categorias utilizadas

- `Added`: novas funcionalidades.
- `Changed`: mudanças em funcionalidades existentes.
- `Deprecated`: funcionalidades marcadas para remoção.
- `Removed`: funcionalidades removidas.
- `Fixed`: correções.
- `Security`: melhorias ou correções de segurança.
