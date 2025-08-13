## Deploying Python Applications in a Docker Swarm Cluster with Traefik Reverse Proxy and HTTPS

In this article, we will explore the process of deploying Python applications in a Docker Swarm cluster, utilizing a Traefik reverse proxy and ensuring secure communication through HTTPS. By following this approach, we can enhance the scalability, availability, and security of our Python applications.

HTTP is not a secure protocol. When deploying a web service using HTTP, it is important to be aware that anyone can intercept the traffic between the browser and the server. An attacker simply needs to use a sniffer tool like Wireshark, for example, to view the traffic in plain text, including passwords and sensitive data. The solution to this issue is to use the HTTPS protocol. HTTPS provides two important benefits: first, it ensures that the server is who it claims to be through certificates, and second, it encrypts the traffic between the client and server. When exposing anything to the internet, the use of HTTPS is considered mandatory. However, in some cases, such as internal APIs within a local network, HTTPS may not be utilized. In this article, we will focus on enabling HTTPS for services in a Docker Swarm cluster. Let's get started.

To achieve this, we will utilize Traefik as a reverse proxy, serving as the sole entry point for our services deployed within the Swarm cluster. Our deployed stacks will not directly expose any ports outside the cluster; instead, they will be mapped to Traefik. Traefik will then handle the task of exposing these services on specific paths. To establish this setup, both our stacks and Traefik will utilize the same external network. Therefore, the first step is to define this network within our cluster.

```shell
docker network create --driver overlay external-net
```

That's our Traefik service configuration

```yaml
version: "3.9"

services:
  traefik:
    image: traefik:v2.10
    command:
      - "--log.level=INFO"
      - "--api.insecure=false"
      - "--api=true"
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedByDefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
    environment:
      - TZ=Europe/Madrid
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"

    networks:
      - external-net

networks:
  external-net:
    external: true
```

Now, let's define our service. In this example, we will have three replicas of a Flask API backend behind a Nginx proxy, which is a common Python scenario.

```python
from flask import Flask
import os

app = Flask(__name__)


@app.get("/service1")
def health():
    return dict(
        status=True,
        slot=os.getenv('SLOT')
    )
```

And that's the configuration of the service:

```yaml
services:
  traefik:
    image: traefik:v3.1
    command:
      - "--log.level=INFO"
      - "--providers.docker=true"
      - "--providers.docker.exposedByDefault=false"
      # Entrypoints
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
    environment:
      - TZ=Europe/Madrid
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
    networks:
      - external-net

networks:
  external-net:
    external: true
```

It uses two images, one for the Flask backend. As we can see in the Dockerfile, we are utilizing a Python 3.11 base image. In the Dockerfile, we set up a non-root user, configure the container, and install dependencies using Poetry.

```Dockerfile
FROM python:3.11 AS base

ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV APP_HOME=/src
ENV APP_USER=appuser

RUN groupadd -r $APP_USER && \
    useradd -r -g $APP_USER -d $APP_HOME -s /sbin/nologin -c "Docker image user" $APP_USER

ENV TZ 'Europe/Madrid'
RUN echo $TZ > /etc/timezone && \
    apt-get update && apt-get install --no-install-recommends -y tzdata && \
    rm /etc/localtime && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata && \
    apt-get clean

RUN pip install --upgrade pip poetry

FROM base

WORKDIR $APP_HOME
COPY --chown=$APP_USER:$APP_USER pyproject.toml poetry.lock ./

RUN poetry config virtualenvs.create false && \
    poetry install --no-root --no-interaction --no-ansi --no-dev

COPY --chown=$APP_USER:$APP_USER src $APP_HOME
RUN find "$APP_HOME" -name '__pycache__' -type d -exec rm -r {} +

RUN chown -R $APP_USER:$APP_USER $APP_HOME

USER $APP_USER
```

We also have a Nginx proxy that serves the replicas of the backend.

```nginx configuration
upstream loadbalancer {
    server backend:5000;
}

server {
    server_tokens off;
    client_max_body_size 20M;
    proxy_busy_buffers_size   512k;
    proxy_buffers   4 512k;
    proxy_buffer_size   256k;
    proxy_set_header Host $host;
    add_header X-Frame-Options SAMEORIGIN;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;
    set_real_ip_from 0.0.0.0/0;
    proxy_read_timeout 300;
    proxy_connect_timeout 300;
    proxy_send_timeout 300;

    location /service1 {
        proxy_pass http://loadbalancer;
    }

    location /service1/health {
        default_type text/html;
        access_log off;
        return 200 'Ok!';
    }
}
```

```Dockerfile
FROM nginx:1.23.4-alpine-slim

RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d
```

With those two containers we can set up the service

```yaml
services:
  nginx:
    image: flaskdemo_nginx:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app.tls=true"
      - "traefik.http.routers.app.rule=Host(`localhost`) && PathPrefix(`/service1`)"
      - "traefik.http.services.app.loadbalancer.server.port=80"
    depends_on:
      - backend
    networks:
      - external-net
      - default-net

  backend:
    image: flaskdemo:latest
    command: gunicorn -w 1 app:app -b 0.0.0.0:5000 --timeout 180
    environment:
      SLOT: "{{.Task.Slot}}"
    deploy:
      replicas: 3
    networks:
      - default-net

networks:
  default-net:
  external-net:
    external: true

```

As we can observe, the magic of Traefik lies within the labels assigned to the exposed service, which in our case is Nginx. These labels define the path that Traefik will utilize to serve the service, specified as "/service1" in our example. Additionally, we instruct Traefik to use HTTPS for this service. It is crucial to ensure that our exposed Nginx service is placed within the same external network as Traefik, as demonstrated by the "external-net" in our example.

On the other hand, the backend service, represented by our Flask application, does not necessarily need to reside in this network. In fact, it is preferable to segregate our service networks, utilizing a private non-external network, such as the "default-net," to establish communication solely between Nginx and the backend.

Note: With this configuration, we are utilizing the default HTTPS certificate provided by Traefik. It should be noted that this certificate does not guarantee server authority, which may result in browser warnings. However, it does ensure that the traffic is encrypted. Alternatively, there are other options available such as using a self-signed certificate, purchasing a certificate from a certificate authority, or obtaining a free valid certificate from Let's Encrypt. However, these alternatives are beyond the scope of this post.

Now ce can build our containers

```shell
docker build -t flaskdemo .
docker build -t flaskdemo_nginx .docker/nginx
```

and deploy to our Swarm cluster (in my example at localhost)

```shell
docker stack deploy -c traefik-stack.yml traefik
docker stack deploy -c service-stack.yml service1
```

And that's it! Our private API is now up and running, utilizing HTTPS for secure communication.
