# syntax=docker/dockerfile:1
ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE}
WORKDIR /app
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN apt-get update && apt-get install -y --no-install-recommends git openssh-client \
    && rm -rf /var/lib/apt/lists/*
COPY requirements-bindmount.txt requirements-silvaengine.txt ./
# The key is available only during this RUN and is never copied into the image.
# --no-deps avoids gateway metadata pulling unrelated engines by bare PyPI name.
RUN --mount=type=secret,id=github_ssh_key,required=true,mode=0400 \
    --mount=type=cache,target=/root/.cache/pip \
    mkdir -p -m 0700 /root/.ssh \
    && ssh-keyscan github.com > /root/.ssh/known_hosts \
    && pip install --index-url "${PIP_INDEX_URL}" -r requirements-bindmount.txt \
    && GIT_SSH_COMMAND="ssh -i /run/secrets/github_ssh_key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes" \
       pip install --index-url "${PIP_INDEX_URL}" --no-deps -r requirements-silvaengine.txt
EXPOSE 8000
CMD ["uvicorn", "silvaengine_gateway.app:create_app_from_env", "--factory", "--host", "0.0.0.0", "--port", "8000"]
