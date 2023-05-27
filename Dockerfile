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
