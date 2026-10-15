#!/usr/bin/env bash
set -euo pipefail

# Dedicated disposable container; never replace an existing local database.
container=makerspace-ci-mongo
trap 'status=$?; if (( status != 0 )); then docker logs "$container" >&2 || true; fi' EXIT
docker run --detach --name "$container" \
  --publish 127.0.0.1:27017:27017 \
  mongo:7.0 mongod --replSet rs0 --bind_ip_all

# Bound the entire connection, initialization and election wait, not just sleeps.
timeout 60s bash -eu -c '
  container=$1
  uri="mongodb://localhost:27017/admin?directConnection=true&serverSelectionTimeoutMS=2000"
  until docker exec "$container" mongosh "$uri" --quiet --eval "quit(db.runCommand({ping:1}).ok ? 0 : 1)"; do
    sleep 1
  done
  docker exec "$container" mongosh "$uri" --quiet --eval '\''
    const result = rs.initiate({_id:"rs0", members:[{_id:0, host:"localhost:27017"}]});
    if (!result.ok) throw new Error("Replica-set initialization failed");
  '\''
  until docker exec "$container" mongosh "$uri" --quiet --eval "quit(db.hello().isWritablePrimary ? 0 : 1)"; do
    sleep 1
  done
' bash "$container"
echo 'MongoDB rs0 is ready.'
