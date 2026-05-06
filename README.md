# Prefect HSJD

Repositorio de configuracion para operar un servidor Prefect 3, sus workers y los deployments de los flujos de BI.

## Estructura

- `server/docker-compose.yml`: levanta PostgreSQL, Redis, Prefect Server, Prefect Services y un worker Docker local.
- `server/prefect-worker.Dockerfile`: imagen del worker Docker con `prefect-docker`.
- `deployments/`: definiciones de deployments Prefect en YAML y un ejemplo en Python.
- `vm_setup.sh`: instalacion de un worker `process` en Ubuntu como servicio de usuario `systemd`.
- `vm_setup_windows.ps1`: instalacion de un worker `process` en Windows como servicio mediante NSSM.
- `requirements.txt`: dependencias minimas para crear deployments desde una maquina cliente.

## Deploy del servidor Prefect

El servidor se despliega desde la carpeta `server/` usando Docker Compose.

```bash
cd server
docker compose up -d --build
```

Servicios levantados:

- `postgres`: base de datos de Prefect.
- `redis`: broker/cache de mensajeria de Prefect.
- `prefect-server`: API y UI de Prefect en el puerto `4200`.
- `prefect-services`: servicios internos de Prefect.
- `prefect-worker`: worker Docker conectado al pool `local-pool`.

La UI queda disponible en:

```text
http://10.0.1.120:4200
```

La API queda disponible en:

```text
http://10.0.1.120:4200/api
```

Si el servidor cambia de IP o hostname, actualizar `PREFECT_API_URL` en:

- `server/docker-compose.yml`
- `vm_setup.sh`
- `vm_setup_windows.ps1`
- los `job_variables.env.PREFECT_API_URL` de los deployments que lo tengan fijo

Comandos utiles:

```bash
cd server
docker compose ps
docker compose logs -f prefect-server
docker compose logs -f prefect-services
docker compose logs -f prefect-worker
docker compose down
```

## Base de datos PostgreSQL

PostgreSQL corre como servicio Docker dentro del mismo Compose:

```yaml
postgres:
  image: postgres:15
```

La conexion usada por Prefect es:

```text
postgresql+asyncpg://prefect:prefect@postgres:5432/prefect
```

La base de datos debe permanecer junto al servidor Prefect, no en las VMs worker. Los workers solo necesitan llegar a la API de Prefect; no se conectan directamente a PostgreSQL.

Los datos se guardan en el volumen Docker nombrado:

```text
postgres_data
```

Dentro del contenedor, PostgreSQL guarda los archivos en:

```text
/var/lib/postgresql/data
```

Para ver el volumen:

```bash
docker volume ls
docker volume inspect server_postgres_data
```

Para backup:

```bash
cd server
docker compose exec postgres pg_dump -U prefect prefect > prefect_backup.sql
```

Para restaurar:

```bash
cd server
docker compose exec -T postgres psql -U prefect prefect < prefect_backup.sql
```

Importante: `docker compose down` no borra la base. `docker compose down -v` si borra los volumenes, incluyendo `postgres_data`.

## Configuracion de workers

Los deployments se ejecutan en work pools. Cada worker debe iniciar apuntando al mismo nombre de pool configurado en el deployment.

### Worker Docker local

El Compose ya incluye un worker Docker:

```yaml
prefect-worker:
  command: prefect worker start --pool local-pool --type docker
```

Este worker usa el socket Docker del host:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
```

Usarlo para deployments cuyo `work_pool.name` sea `local-pool`, por ejemplo `daily_reminder_report.yaml`.

### Worker Ubuntu

Para preparar una VM Ubuntu:

```bash
bash vm_setup.sh
```

El script solicita el nombre del pool, crea un entorno virtual en `~/prefect`, instala Prefect y registra un servicio de usuario:

```bash
systemctl --user status prefect-worker
journalctl --user -u prefect-worker -f
```

Por defecto apunta a:

```text
PREFECT_API_URL=http://10.0.1.120:4200/api
```

El worker se inicia como tipo `process`:

```bash
prefect worker start --pool "<nombre-del-pool>" --type process
```

Usar este modo para pools como `vm-BI1`, `vm-BI2`, `vm-BI6`, `vm-farmacia` o `vm_reportes`, segun corresponda.

### Worker Windows

Para preparar una VM Windows, ejecutar PowerShell:

```powershell
.\vm_setup_windows.ps1
```

El script:

- crea `C:\Users\<usuario>\prefect`
- crea un entorno virtual
- instala Prefect
- descarga NSSM
- registra un servicio `PrefectWorker-<pool>`

El worker tambien apunta a:

```text
PREFECT_API_URL=http://10.0.1.120:4200/api
```

Usar este modo para pools Windows, por ejemplo `vm-windows-234`.

### Crear o validar work pools

Desde una maquina con Prefect instalado y acceso a la API:

```bash
export PREFECT_API_URL=http://10.0.1.120:4200/api
prefect work-pool ls
prefect work-pool create local-pool --type docker
prefect work-pool create vm-BI1 --type process
```

Los nombres de pool deben coincidir exactamente con los definidos en `deployments/*.yaml`.

## Variables, bloques y credenciales

Varios deployments clonan repositorios privados desde GitHub:

```yaml
credentials: "{{ prefect.blocks.github-credentials.bi-github }}"
```

Antes de aplicar esos deployments debe existir el bloque `github-credentials/bi-github` en Prefect.

Tambien se usa la variable:

```yaml
{{ prefect.variables.deployment_branch }}
```

Crear o actualizar la variable desde CLI:

```bash
export PREFECT_API_URL=http://10.0.1.120:4200/api
prefect variable set deployment_branch main --overwrite
```

Si un deployment requiere credenciales, tokens o passwords, preferir bloques/variables de Prefect antes que dejarlos hardcodeados en YAML.

## Crear nuevos deployments

Hay dos formas usadas en este repo: YAML con `prefect deploy` y Python con `.deploy()`.

### Opcion recomendada: YAML

Crear un archivo en `deployments/`, por ejemplo:

```yaml
name: mi-proyecto
prefect-version: 3.6.25

pull:
  - prefect.deployments.steps.git_clone:
      id: clone-step
      repository: https://github.com/HSJD-BI/mi-proyecto.git
      branch: "{{ prefect.variables.deployment_branch }}"
      credentials: "{{ prefect.blocks.github-credentials.bi-github }}"
  - prefect.deployments.steps.run_shell_script:
      script: uv pip install -r requirements.txt
      stream_output: true
      directory: "{{ clone-step.directory }}"

deployments:
  - name: deploy-mi-flow
    description: "Descripcion corta del proceso."
    flow_name: mi-flow
    entrypoint: flows/flow.py:mi_flow
    work_pool:
      name: "vm-BI1"
      job_variables:
        env:
          PREFECT_API_URL: "http://10.0.1.120:4200/api"
          TESTING: "false"
    schedules:
      - cron: "0 8 * * *"
        timezone: "America/Buenos_Aires"
        active: true
```

Aplicar el deployment:

```bash
export PREFECT_API_URL=http://10.0.1.120:4200/api
prefect deploy --prefect-file deployments/mi-proyecto.yaml --all
```

Si el deployment no tiene schedule, se puede ejecutar manualmente desde la UI o por CLI:

```bash
prefect deployment run "mi-flow/deploy-mi-flow"
```

### Deployment con imagen Docker

Para flows que deban ejecutarse en el worker Docker `local-pool`, usar el patron de `deployments/daily_reminder_report.yaml`:

```yaml
build:
  - prefect_docker.deployments.steps.build_docker_image:
      id: build-image
      requires: prefect-docker>=0.3.0
      image_name: docker.io/usuario/imagen
      tag: latest
      dockerfile: dockerfile

push:
  - prefect_docker.deployments.steps.push_docker_image:
      id: push-image
      requires: prefect-docker
      image_name: "{{ build-image.image_name }}"
      tag: "{{ build-image.tag }}"

deployments:
  - name: deploy-ejemplo
    flow_name: ejemplo-flow
    entrypoint: flows/flow.py:ejemplo_flow
    work_pool:
      name: "local-pool"
      job_variables:
        image: "{{ build-image.image }}"
        network_mode: "host"
```

Antes de publicar este tipo de deployment, iniciar sesion en el registry Docker correspondiente:

```bash
docker login
prefect deploy --prefect-file deployments/archivo.yaml --all
```

### Opcion Python

`deployments/deploy_sample_flow.py` muestra un deployment creado desde codigo:

```bash
export PREFECT_API_URL=http://10.0.1.120:4200/api
python deployments/deploy_sample_flow.py
```

Este enfoque sirve para casos simples, pero para los proyectos productivos conviene mantener YAML porque deja versionados pull steps, schedules, work pools y variables de entorno.

## Checklist para agregar un flujo nuevo

1. Confirmar en que VM o worker debe correr.
2. Crear el work pool si todavia no existe.
3. Verificar que el worker este activo y conectado al pool.
4. Crear el YAML en `deployments/`.
5. Definir `entrypoint` como `ruta/al_archivo.py:nombre_del_flow`.
6. Agregar `pull` para clonar el repo y instalar dependencias.
7. Agregar `job_variables.env` necesarias.
8. Configurar schedule si corresponde.
9. Ejecutar `prefect deploy --prefect-file deployments/<archivo>.yaml --all`.
10. Probar una corrida manual desde la UI o con `prefect deployment run`.

## Troubleshooting

Verificar conexion a la API:

```bash
export PREFECT_API_URL=http://10.0.1.120:4200/api
prefect version
```

Ver workers conectados:

```bash
prefect work-pool ls
```

Ver estado del server:

```bash
cd server
docker compose ps
docker compose logs -f prefect-server
```

Ver logs de worker Ubuntu:

```bash
journalctl --user -u prefect-worker -f
```

Si un deployment queda en `Late` o `Pending`, revisar:

- que el schedule este activo
- que exista un worker conectado al mismo `work_pool.name`
- que `PREFECT_API_URL` apunte al servidor correcto
- que el worker tenga acceso al repositorio GitHub
- que las variables y bloques usados por el YAML existan en Prefect
- que las dependencias del repo se instalen correctamente
