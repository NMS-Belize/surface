FROM python:3.9-bullseye
LABEL authors="Roberto Santos, Tadashi Igarashi"

ENV PYTHONUNBUFFERED 1
ENV DJANGO_SETTINGS_MODULE tempestas_api.settings

RUN apt-get update --fix-missing
RUN apt-get install -y g++ libgdal-dev libpq-dev libgeos-dev libproj-dev vim wait-for-it
RUN apt-get install -y openjdk-17-jre
RUN apt-get install -y postgresql-client

RUN adduser --disabled-password --gecos '' surface && mkdir /surface && chown -R surface /surface
WORKDIR /surface

RUN mkdir -p /data/documents/ingest
RUN mkdir -p /data/media
RUN mkdir -p /data/backup
RUN mkdir -p /data/shared
RUN mkdir -p /data/exported_data
RUN chown -R surface /data

COPY load_initial_data.sh .
RUN chmod +x load_initial_data.sh

USER surface

RUN pip install -U "pip<24.1" setuptools wheel
RUN pip install numpy==1.21.2 --force-reinstall

COPY requirements.txt /requirements.txt
RUN pip install -r /requirements.txt --no-warn-script-location
CMD ./startup.sh