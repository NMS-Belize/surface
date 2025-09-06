from __future__ import absolute_import, unicode_literals

import os

from django.conf import settings

from celery import Celery

# set the default Django settings module for the 'celery' program.
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'tempestas_api.settings')

app = Celery('tempestas_api')
# app.conf.broker_url = 'redis://surface_redis:6379/0'
app.conf.broker_url = settings.SURFACE_BROKER_URL

# setting up a results backend
app.conf.result_backend = settings.SURFACE_BROKER_URL
# app.conf.result_expires = 3600  # Results expire after 1 hour


# Using a string here means the worker doesn't have to serialize
# the configuration object to child processes.
# - namespace='CELERY' means all celery-related configuration keys
#   should have a `CELERY_` prefix.
app.config_from_object('django.conf:settings', namespace='CELERY')

app.conf.beat_schedule = {
    'predict_preciptation_data': {
        'task': 'wx.tasks.predict_preciptation_data',
        'schedule': 3600,
    },
    'dcp_tasks_scheduler': {
        'task': 'wx.tasks.dcp_tasks_scheduler',
        'schedule': 60,
    },
    'process_hourly_summary_tasks': {
        'task': 'wx.tasks.process_hourly_summary_tasks',
        'schedule': 120
    },
    'process_daily_summary_tasks': {
        'task': 'wx.tasks.process_daily_summary_tasks',
        'schedule': 600
    },
    'ftp_ingest_historical_station_files': {
        'task': 'wx.tasks.ftp_ingest_historical_station_files',
        'schedule': 60
    },
    'ftp_ingest_not_historical_station_files': {
        'task': 'wx.tasks.ftp_ingest_not_historical_station_files',
        'schedule': 60
    },
    'calculate_last24h_summary': {
        'task': 'wx.tasks.calculate_last24h_summary',
        'schedule': 300
    },
    'ftp_ingest_highfrequency_station_files': {
        'task': 'wx.tasks.ftp_ingest_highfrequency_station_files',
        'schedule': 60
    },        
    'process_hfdata_summary_tasks': {
        'task': 'wx.tasks.process_hfdata_summary_tasks',
        'schedule': 60
    },
    # backup the db
    'backup_postgres': {
        'task': 'wx.tasks.backup_postgres',
        'schedule': 60
    },
    ## Wava data simulator
    'gen_hf_data': {
        'task': 'wx.tasks.gen_toa5_file',
        'schedule': 900
    },    
    ## wis2box publish clean up (runs every 5 min)
    'wis2box_cleanup': {
        'task': 'wx.tasks.wis2publish_cleanup',
        'schedule': 300
    }, 
    ## wis2box push task runs every minute (checks the cron schedule of publishing stations then pushes to wis2box)      
    'wis2box_publish': {
        'task': 'wx.tasks.wis2publish_task',
        'schedule': 60
    },
}

app.conf.timezone = 'UTC'

# Load task modules from all registered Django app configs.
app.autodiscover_tasks()


@app.task(bind=True)
def debug_task(self):
    print('Request: {0!r}'.format(self.request))
