#!/usr/bin/env bash
# Corre una tarea de ECS de una sola vez (la inicialización de la base) y falla si el contenedor no termina
# con código 0. Lo llama terraform_data.db_init con las variables CLUSTER, TASK_DEFINITION, SUBNETS y
# SECURITY_GROUP.
set -euo pipefail

network="awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${SECURITY_GROUP}],assignPublicIp=ENABLED}"
task=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TASK_DEFINITION" --launch-type FARGATE \
  --network-configuration "$network" --query 'tasks[0].taskArn' --output text)
echo "run-task: $task"

# `aws ecs wait tasks-stopped` se rinde a los 10 minutos; la tarea tarda 1 o 2.
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task"

read -r code reason < <(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" \
  --query 'tasks[0].[containers[0].exitCode, stoppedReason]' --output text)
echo "run-task: código de salida ${code} (${reason})"
[ "$code" = "0" ] || { echo "run-task: falló; ver los logs en CloudWatch (/ecs/festa-*/db-init)" >&2; exit 1; }
