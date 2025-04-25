import datetime
import io
import json
import logging
import os
import zipfile
import shutil
import random
import uuid
import wx.export_surface_oscar as exso
import pyoscar
from datetime import datetime as datetime_constructor
from datetime import timezone, timedelta

import matplotlib

matplotlib.use("Agg")
import cv2
import matplotlib.pyplot as plt
import pandas as pd
from openpyxl import Workbook
import tempfile
import psycopg2
import pytz
import django.conf
from django.contrib import messages
from django.core.files.base import ContentFile
from django.core.paginator import Paginator
from django.contrib.auth.mixins import LoginRequiredMixin
from django.contrib.messages.views import SuccessMessageMixin
from django.core.cache import cache
from django.shortcuts import get_object_or_404
from django.core.exceptions import ObjectDoesNotExist
from django.db import connection
from django.http import HttpResponse, JsonResponse, FileResponse, HttpResponseNotAllowed
from django.template import loader
from django.urls import reverse
from django.views.decorators.csrf import csrf_exempt
from django.views.generic.base import TemplateView
from django.views.generic.detail import DetailView
from django.views.generic.edit import CreateView, UpdateView, DeleteView
from django.views.generic.list import ListView
from geopandas import geopandas
from material import *
from matplotlib.backends.backend_agg import FigureCanvasAgg as FigureCanvas
from matplotlib.transforms import Bbox
from metpy.interpolate import interpolate_to_grid
from pandas import json_normalize
from rest_framework import viewsets, status, generics, views, permissions
from rest_framework.decorators import api_view, permission_classes
from rest_framework.parsers import FileUploadParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from slugify import slugify
from celery.result import AsyncResult

from tempestas_api import settings
from wx import serializers, tasks
from wx.decoders import insert_raw_data_pgia, insert_raw_data_synop
from wx.decoders.hobo import read_file as read_file_hobo
from wx.decoders.toa5 import read_file
from wx.forms import StationForm
from wx.models import AdministrativeRegion, StationFile, Decoder, QualityFlag, DataFile, DataFileStation, \
    DataFileVariable, StationImage, WMOStationType, WMORegion, WMOProgram, StationCommunication, CombineDataFile, ManualStationDataFile
from wx.models import Country, Unit, Station, Variable, DataSource, StationVariable, StationDataFileStatus,\
    StationProfile, Document, Watershed, Interval, CountryISOCode, Wis2BoxPublish, Wis2PublishOffset, LocalWisCredentials, RegionalWisCredentials,  Wis2BoxPublishLogs
from wx.utils import get_altitude, get_watershed, get_district, get_interpolation_image, parse_float_value, \
    parse_int_value
from .utils import get_raw_data, get_station_raw_data
from wx.models import MaintenanceReport, VisitType, Technician
from django.views.decorators.http import require_http_methods
from base64 import b64encode

from wx.models import QualityFlag
import time
from wx.models import HighFrequencyData, MeasurementVariable
from wx.tasks import fft_decompose, export_station_to_oscar, export_station_to_oscar_wigos
import math
import numpy as np

from wx.models import Equipment, EquipmentType, Manufacturer, FundingSource, StationProfileEquipmentType
from django.core.serializers import serialize
from django.core.serializers.json import DjangoJSONEncoder
from wx.models import MaintenanceReportEquipment
from wx.models import QcRangeThreshold, QcStepThreshold, QcPersistThreshold
from simple_history.utils import update_change_reason
from django.db.models.functions import Cast
from django.db.models import IntegerField
from django.utils.timezone import localtime


from wx.models import WMOCodeValue

logger = logging.getLogger('surface.urls')

# CONSTANT to be used in datetime to milliseconds conversion
EPOCH = datetime_constructor(1970, 1, 1, tzinfo=timezone.utc)


@csrf_exempt
def ScheduleDataExport(request):
    if request.method != 'POST':
        return HttpResponse(status=405)

    # access values from the response
    json_body = json.loads(request.body)
    station_ids = json_body['stations']  # array with station ids

    data_source = json_body['source']  # could be either raw_data, hourly_summary, daily_summary, monthly_summary or yearly_summary

    start_date = json_body['start_datetime']  # in format %Y-%m-%d %H:%M:%S

    end_date = json_body['end_datetime']  # in format %Y-%m-%d %H:%M:%S

    variable_ids = json_body['variables']  # list of obj in format {id: Int, agg: Str}

    aggregation = json_body['aggregation'] # sets which column in the db will be used when the source is a summary. 

    displayUTC = json_body['displayUTC'] # determins wheter an offset will be applied based on the truthines of displayUTC

    # If source is raw_data, this will be set to none
    if data_source == 'raw_data':
        aggregation = None

    data_interval_seconds = None
    if data_source == 'raw_data' and 'data_interval' in json_body:  # a number with the data interval in seconds. Only required for raw_data
        data_interval_seconds = json_body['data_interval']
    elif data_source == 'raw_data':
        data_interval_seconds = 300

    created_data_file_ids = []
    start_date_utc = pytz.UTC.localize(datetime.datetime.strptime(start_date, '%Y-%m-%d %H:%M:%S'))
    end_date_utc = pytz.UTC.localize(datetime.datetime.strptime(end_date, '%Y-%m-%d %H:%M:%S'))

    if start_date_utc > end_date_utc:
        message = 'The initial date must be greater than final date.'
        return JsonResponse(data={"message": message}, status=status.HTTP_400_BAD_REQUEST)

    days_interval = (end_date_utc - start_date_utc).days

    data_source_dict = {
        "raw_data": "Raw Data",
        "hourly_summary": "Hourly Summary",
        "daily_summary": "Daily Summary",
        "monthly_summary": "Monthly Summary",
        "yearly_summary": "Yearly Summary",
    }

    data_source_description = data_source_dict[data_source]

    prepared_by = None
    if request.user.first_name and request.user.last_name:
        prepared_by = f'{request.user.first_name} {request.user.last_name}'
    else:
        prepared_by = request.user.username

    for station_id in station_ids:
        if aggregation:
            for agg in aggregation:
                newfile = DataFile.objects.create(ready=False, initial_date=start_date_utc, final_date=end_date_utc,
                                                source=data_source_description, prepared_by=prepared_by,
                                                interval_in_seconds=data_interval_seconds)
                DataFileStation.objects.create(datafile=newfile, station_id=station_id)

                for variable_id in variable_ids:
                    variable = Variable.objects.get(pk=variable_id)
                    DataFileVariable.objects.create(datafile=newfile, variable=variable)

                tasks.export_data.delay(station_id, data_source, start_date, end_date, variable_ids, newfile.id, agg, displayUTC)
                created_data_file_ids.append(newfile.id)
        else:
            newfile = DataFile.objects.create(ready=False, initial_date=start_date_utc, final_date=end_date_utc,
                                            source=data_source_description, prepared_by=prepared_by,
                                            interval_in_seconds=data_interval_seconds)
            DataFileStation.objects.create(datafile=newfile, station_id=station_id)

            for variable_id in variable_ids:
                variable = Variable.objects.get(pk=variable_id)
                DataFileVariable.objects.create(datafile=newfile, variable=variable)

            tasks.export_data.delay(station_id, data_source, start_date, end_date, variable_ids, newfile.id, aggregation, displayUTC)
            created_data_file_ids.append(newfile.id)

    return JsonResponse({'data': created_data_file_ids}, status=status.HTTP_200_OK)


@api_view(('GET',))
def DataExportFiles(request):
    files = []
    for df in DataFile.objects.all().order_by('-created_at').values()[:100:1]:
        if df['ready'] and df['ready_at']:
            file_status = {'text': "Ready", 'value': 1}
        elif df['ready_at']:
            file_status = {'text': "Error", 'value': 2}
        else:
            file_status = {'text': "Processing", 'value': 0}

        current_station_name = None
        try:
            current_data_file = DataFileStation.objects.get(datafile_id=df['id'])
            current_station = Station.objects.get(pk=current_data_file.station_id)
            current_station_name = current_station.name
        except ObjectDoesNotExist:
            current_station_name = "Station not found"

        f = {
            'id': df['id'],
            'request_date': df['created_at'],
            'ready_date': df['ready_at'],
            'station': current_station_name,
            'variables': [],
            'status': file_status,
            'initial_date': df['initial_date'],
            'final_date': df['final_date'],
            'source': {'text': df['source'],
                       'value': 0 if df['source'] == 'Raw data' else (1 if df['source'] == 'Hourly summary' else 2)},
            'lines': df['lines'],
            'prepared_by': df['prepared_by'],
        }
        if f['ready_date'] is not None:
            f['ready_date'] = f['ready_date']
        for fv in DataFileVariable.objects.filter(datafile_id=df['id']).values():
            f['variables'].append(Variable.objects.filter(pk=fv['variable_id']).values()[0]['name'])
        files.append(f)

    return Response(files, status=status.HTTP_200_OK)


def DownloadDataFile(request):
    file_id = request.GET.get('id', None)
    # for combine xlsx downloads
    if 'combine' in str(file_id):
        file_path = os.path.join('/data', 'exported_data', str(file_id) + '.xlsx')
    else:
        file_path = os.path.join('/data', 'exported_data', str(file_id) + '.csv')
    if os.path.exists(file_path):
        # with open(file_path, 'rb') as fh:
        #     response = HttpResponse(fh.read(), content_type="text/csv")
        #     response['Content-Disposition'] = 'inline; filename=' + os.path.basename(file_path)
        #     return response
        return FileResponse(open(file_path, 'rb'), as_attachment=True, filename=os.path.basename(file_path))
    return JsonResponse({}, status=status.HTTP_404_NOT_FOUND)


# download .xlsx version of the data file
def DownloadDataFileXLSX(request):
    # file id of the csv to be converted to .xlsx
    file_id = request.GET.get('id', None)
    # path to the xlsx file
    xlsx_file_path = os.path.join('/data', 'exported_data', str(file_id) + '.xlsx')
    # path to the csv file
    file_path = os.path.join('/data', 'exported_data', str(file_id) + '.csv')

    try:
        if not os.path.exists(xlsx_file_path):
            # if the .xlsx file does not exist then create it
            tasks.convert_csv_xlsx(file_path, file_id, file_id)

        return FileResponse(open(xlsx_file_path, 'rb'), as_attachment=True, filename=os.path.basename(xlsx_file_path))
    
    except Exception as e:
        logger.error(f"An error occured while trying to download {file_id}.xlsx. Error code: {e}")
    
    # return 404 on error
    return JsonResponse({}, status=status.HTTP_404_NOT_FOUND)


# combine csv files into a .xlsx file and then download them
@csrf_exempt
def CombineFilesXLSX(request):
    # ensure that the request method is post
    if request.method != 'POST':
        # else return the "method not allowed" error in response
        return HttpResponse(status=405)
    
    # processing the request
    try:
        # ensuring that the start date and the end date are valid
        json_body = json.loads(request.body)
        # grabbing the start and the end date
        start_date = json_body['start_datetime']  # in format %Y-%m-%d %H:%M:%S

        end_date = json_body['end_datetime']  # in format %Y-%m-%d %H:%M:%S

        start_date_utc = pytz.UTC.localize(datetime.datetime.strptime(start_date, '%Y-%m-%d %H:%M:%S'))
        end_date_utc = pytz.UTC.localize(datetime.datetime.strptime(end_date, '%Y-%m-%d %H:%M:%S'))
        # ensuring that the start date and the end date are valid
        if start_date_utc > end_date_utc:
            message = 'The initial date must be greater than final date.'
            return JsonResponse(data={"message": message}, status=status.HTTP_400_BAD_REQUEST)

        station_ids = json_body['stations']  # array with station ids

        data_source = json_body['source']  # could be either raw_data, hourly_summary, daily_summary, monthly_summary or yearly_summary

        variable_ids = json_body['variables']  # list of obj in format {id: Int, agg: Str}

        aggregation = json_body['aggregation'] # sets which column in the db will be used when the source is a summary. 

        displayUTC = json_body['displayUTC'] # determins wheter an offset will be applied based on the truthines of displayUTC

        # If source is raw_data, aggregation will be set to none
        if data_source == 'raw_data':
            aggregation = ""

        data_interval_seconds = None
        if data_source == 'raw_data' and 'data_interval' in json_body:  # a number with the data interval in seconds. Only required for raw_data
            data_interval_seconds = json_body['data_interval']
        elif data_source == 'raw_data':
            data_interval_seconds = 300

        prepared_by = None
        if request.user.first_name and request.user.last_name:
            prepared_by = f'{request.user.first_name} {request.user.last_name}'
        else:
            prepared_by = request.user.username

        data_source_dict = {
            "raw_data": "Raw Data",
            "hourly_summary": "Hourly Summary",
            "daily_summary": "Daily Summary",
            "monthly_summary": "Monthly Summary",
            "yearly_summary": "Yearly Summary",
        }

        data_source_description = data_source_dict[data_source]

        # converting the station_ids into a string to pass to the new entry
        station_ids_string = ""
        for x in station_ids:
            station_ids_string += str(x) + "_"

        # converting the variable_ids into a string to pass to the new entry
        variable_ids_string = ""
        for y in variable_ids:
            variable_ids_string += str(y) + "_"

        # add this file entry to the combine data file model
        new_entry = CombineDataFile.objects.create(ready=False, initial_date=start_date_utc, final_date=end_date_utc,
                                                        source=data_source_description, prepared_by=prepared_by,
                                                        stations_ids=station_ids_string, variable_ids=variable_ids_string, aggregation="  ".join(aggregation).upper())

        # send the MAIN task unto celery
        combine_task = tasks.combine_xlsx_files.delay(station_ids, data_source, start_date, end_date, variable_ids, aggregation, displayUTC, data_interval_seconds, prepared_by, data_source_description, new_entry.id)
        print(f'BTW THIS IS THE NEW_ENTRY ID::::::::{new_entry.id}')
        return JsonResponse({'data': new_entry.id}, status=status.HTTP_200_OK)
    except Exception as e:
        logger.error(f'An error occured while attempting to schedule combine task. Error = {e}')
        return JsonResponse({"error": str(e)}, status=500)


# get an update on the combine files
@api_view(('GET',))
def combineDataExportFiles(request):
    files = []
    try:
        for df in CombineDataFile.objects.all().order_by('-created_at').values()[:100:1]:
            if df['ready'] and df['ready_at']:
                file_status = {'text': "Ready", 'value': 1}
            elif df['ready_at']:
                file_status = {'text': "Error", 'value': 2}
            else:
                file_status = {'text': "Processing", 'value': 0}

            # getting the stations list
            current_station_names_list = []
            try:
                station_ids = str(df['stations_ids']).split('_')

                for x in station_ids:
                    if x:
                        current_station_names_list.append(Station.objects.get(pk=int(x)).name)

            except ObjectDoesNotExist:
                current_station_names_list = ["Stations not found"]


            # getting variables list
            variable_list = []
            try:
                variable_ids = str(df['variable_ids']).split('_')

                for y in variable_ids:
                    if y:
                        variable_list.append(Variable.objects.get(pk=int(y)).name)

            except Exception as e:
                # logger.warning(f'An warning occurd during variable list creation: {variable_ids}')
                variable_list = ["No variables"]

            f = {
                'id': df['id'],
                'request_date': df['created_at'],
                'ready_date': df['ready_at'],
                'station': current_station_names_list,
                'variables': variable_list,
                'status': file_status,
                'initial_date': df['initial_date'],
                'final_date': df['final_date'],
                'source': {'text': df['source'],
                        'value': 0 if df['source'] == 'Raw data' else (1 if df['source'] == 'Hourly summary' else 2)},
                'lines': df['lines'],
                'prepared_by': df['prepared_by'],
                'aggregation': df['aggregation'],
            }
            if f['ready_date'] is not None:
                f['ready_date'] = f['ready_date']
            files.append(f)

        return Response(files, status=status.HTTP_200_OK)

    except Exception as e:
        logger.warning(f"An error occured while attempting to update the combined .xlsx files table. Error - {e}")
        return JsonResponse({"error": str(e)}, status=500)


# to delete data file
def DeleteDataFile(request):
    file_id = request.GET.get('id', None)

    if 'combine' in str(file_id):
        entry_id = int(str(file_id).split('-')[-1])

        CombineDataFile.objects.get(pk=entry_id).delete()

        file_path = os.path.join('/data', 'exported_data', str(file_id) + '.xlsx')

        if os.path.exists(file_path):
            os.remove(file_path)
        return JsonResponse({}, status=status.HTTP_200_OK)

    df = DataFile.objects.get(pk=file_id)
    DataFileStation.objects.filter(datafile=df).delete()
    DataFileVariable.objects.filter(datafile=df).delete()
    df.delete()
    file_path = os.path.join('/data', 'exported_data', str(file_id) + '.csv')
    if os.path.exists(file_path):
        os.remove(file_path)
    return JsonResponse({}, status=status.HTTP_200_OK)


def GetInterpolationData(request):
    start_datetime = request.GET.get('start_datetime', None)
    end_datetime = request.GET.get('end_datetime', None)
    variable_id = request.GET.get('variable_id', None)
    agg = request.GET.get('agg', "instant")
    source = request.GET.get('source', "raw_data")
    quality_flags = request.GET.get('quality_flags', None)

    where_query = ""
    if source == "raw_data":
        dt_query = "datetime"
        value_query = "measured"
        source_query = "raw_data"
        if quality_flags:
            try:
                [int(qf) for qf in quality_flags.split(',')]
            except ValueError:
                return JsonResponse({"message": "Invalid quality_flags value."}, status=status.HTTP_400_BAD_REQUEST)
            where_query = f" measured != {settings.MISSING_VALUE} AND quality_flag IN ({quality_flags}) AND "
        else:
            where_query = f" measured != {settings.MISSING_VALUE} AND "
    else:
        with connection.cursor() as cursor:
            cursor.execute("""
                SELECT sampling_operation_id
                FROM wx_variable
                WHERE id=%(variable_id)s;
                """,
                           params={'variable_id': variable_id}
                           )
            sampling_operation = cursor.fetchone()[0]

        if sampling_operation in [6, 7]:
            value_query = "sum_value"
        elif sampling_operation == 3:
            value_query = "min_value"
        elif sampling_operation == 4:
            value_query = "max_value"
        else:
            value_query = "avg_value"

        if source == "hourly":
            dt_query = "datetime"
            source_query = "hourly_summary"

        elif source == "daily":
            dt_query = "day"
            source_query = "daily_summary"

        elif source == "monthly":
            dt_query = "date"
            source_query = "monthly_summary"

        elif source == "yearly":
            dt_query = "date"
            source_query = "yearly_summary"

    if agg == "instant":
        where_query += "variable_id=%(variable_id)s AND " + dt_query + "=%(datetime)s"
        params = {'datetime': start_datetime, 'variable_id': variable_id}
    else:
        where_query += "variable_id=%(variable_id)s AND " + dt_query + " >= %(start_datetime)s AND " + dt_query + " <= %(end_datetime)s"
        params = {'start_datetime': start_datetime, 'end_datetime': end_datetime, 'variable_id': variable_id}

    with connection.cursor() as cursor:
        cursor.execute("""
            SELECT a.station_id,b.name,b.code,b.latitude,b.longitude,a.""" + value_query + """ as measured
            FROM """ + source_query + """ a INNER JOIN wx_station b ON a.station_id=b.id
            WHERE """ + where_query + ";",
                       params=params
                       )
        climate_data = {}
        # if agg == "instant":
        raw_data = cursor.fetchall()
        climate_data['data'] = []
        for item in raw_data:
            climate_data['data'].append({
                'station_id': item[0],
                'name': item[1],
                'code': item[2],
                'latitude': item[3],
                'longitude': item[4],
                'measured': item[5],
            })

    if agg != "instant" and len(raw_data) > 0:
        columns = ['station_id', 'name', 'code', 'latitude', 'longitude', 'measured']
        df_climate = json_normalize([
            dict(zip(columns, row))
            for row in raw_data
        ])

        climate_data['data'] = json.loads(
            df_climate.groupby(['station_id', 'name', 'code', 'longitude', 'latitude']).agg(
                agg).reset_index().sort_values('name').to_json(orient="records"))

    return JsonResponse(climate_data)


def GetInterpolationImage(request):
    start_datetime = request.GET.get('start_datetime', None)
    end_datetime = request.GET.get('end_datetime', None)
    variable_id = request.GET.get('variable_id', None)
    cmap = request.GET.get('cmap', 'Spectral_r')
    hres = request.GET.get('hres', 0.01)
    minimum_neighbors = request.GET.get('minimum_neighbors', 1)
    search_radius = request.GET.get('search_radius', 0.7)
    agg = request.GET.get('agg', "instant")
    source = request.GET.get('source', "raw_data")
    vmin = request.GET.get('vmin', 0)
    vmax = request.GET.get('vmax', 30)
    quality_flags = request.GET.get('quality_flags', None)

    stations_df = pd.read_sql_query("""
        SELECT id,name,alias_name,code,latitude,longitude
        FROM wx_station
        WHERE longitude!=0;
        """,
                                    con=connection
                                    )
    stations = geopandas.GeoDataFrame(
        stations_df, geometry=geopandas.points_from_xy(stations_df.longitude, stations_df.latitude))
    stations.crs = 'epsg:4326'

    stands_llat = settings.SPATIAL_ANALYSIS_INITIAL_LATITUDE
    stands_llon = settings.SPATIAL_ANALYSIS_INITIAL_LONGITUDE
    stands_ulat = settings.SPATIAL_ANALYSIS_FINAL_LATITUDE
    stands_ulon = settings.SPATIAL_ANALYSIS_FINAL_LONGITUDE

    where_query = ""
    if source == "raw_data":
        dt_query = "datetime"
        value_query = "measured"
        source_query = "raw_data"
        if quality_flags:
            try:
                [int(qf) for qf in quality_flags.split(',')]
            except ValueError:
                return JsonResponse({"message": "Invalid quality_flags value."}, status=status.HTTP_400_BAD_REQUEST)
            where_query = f" measured != {settings.MISSING_VALUE} AND quality_flag IN ({quality_flags}) AND "
        else:
            where_query = f" measured != {settings.MISSING_VALUE} AND "
    else:
        with connection.cursor() as cursor:
            cursor.execute("""
                SELECT sampling_operation_id
                FROM wx_variable
                WHERE id=%(variable_id)s;
                """,
                           params={'variable_id': variable_id}
                           )
            sampling_operation = cursor.fetchone()[0]

        if sampling_operation in [6, 7]:
            value_query = "sum_value"
        elif sampling_operation == 3:
            value_query = "min_value"
        elif sampling_operation == 4:
            value_query = "max_value"
        else:
            value_query = "avg_value"

        if source == "hourly":
            dt_query = "datetime"
            source_query = "hourly_summary"

        elif source == "daily":
            dt_query = "day"
            source_query = "daily_summary"

        elif source == "monthly":
            dt_query = "date"
            source_query = "monthly_summary"

        elif source == "yearly":
            dt_query = "date"
            source_query = "yearly_summary"

    if agg == "instant":
        where_query += "variable_id=%(variable_id)s AND " + dt_query + "=%(datetime)s"
        params = {'datetime': start_datetime, 'variable_id': variable_id}
    else:
        where_query += "variable_id=%(variable_id)s AND " + dt_query + " >= %(start_datetime)s AND " + dt_query + " <= %(end_datetime)s"
        params = {'start_datetime': start_datetime, 'end_datetime': end_datetime, 'variable_id': variable_id}

    climate_data = pd.read_sql_query(
        "SELECT station_id,variable_id," + dt_query + "," + value_query + """
        FROM """ + source_query + """
        WHERE """ + where_query + ";",
        params=params,
        con=connection
    )

    if len(climate_data) == 0:
        with open("/surface/static/images/no-interpolated-data.png", "rb") as f:
            img_data = f.read()

        return HttpResponse(img_data, content_type="image/jpeg")

    df_merged = pd.merge(left=climate_data, right=stations, how='left', left_on='station_id', right_on='id')
    df_climate = df_merged[["station_id", dt_query, "longitude", "latitude", value_query]]

    if agg != "instant":
        df_climate = df_climate.groupby(['station_id', 'longitude', 'latitude']).agg(agg).reset_index()

    gx, gy, img = interpolate_to_grid(
        df_climate["longitude"],
        df_climate["latitude"],
        df_climate[value_query],
        interp_type='cressman',
        minimum_neighbors=int(minimum_neighbors),
        hres=float(hres),
        search_radius=float(search_radius),
        boundary_coords={'west': stands_llon, 'east': stands_ulon, 'south': stands_llat, 'north': stands_ulat}
    )

    fig = plt.figure(frameon=False)
    ax = plt.Axes(fig, [0., 0., 1., 1.])
    ax.set_axis_off()
    fig.add_axes(ax)
    ax.imshow(img, origin='lower', cmap=cmap, vmin=vmin, vmax=vmax)
    fname = str(uuid.uuid4())
    fig.savefig("/surface/static/images/" + fname + ".png", dpi='figure', format='png', transparent=True,
                bbox_inches=Bbox.from_bounds(2, 0, 2.333, 4.013))
    image1 = cv2.imread("/surface/static/images/" + fname + ".png", cv2.IMREAD_UNCHANGED)
    image2 = cv2.imread(settings.SPATIAL_ANALYSIS_SHAPE_FILE_PATH, cv2.IMREAD_UNCHANGED)
    image1 = cv2.resize(image1, dsize=(image2.shape[1], image2.shape[0]))
    for i in range(image1.shape[0]):
        for j in range(image1.shape[1]):
            image1[i][j][3] = image2[i][j][3]
    cv2.imwrite("/surface/static/images/" + fname + "-output.png", image1)

    with open("/surface/static/images/" + fname + "-output.png", "rb") as f:
        img_data = f.read()

    os.remove("/surface/static/images/" + fname + ".png")
    os.remove("/surface/static/images/" + fname + "-output.png")

    return HttpResponse(img_data, content_type="image/jpeg")


def GetColorMapBar(request):
    start_datetime_req = request.GET.get('start_datetime', '')
    end_datetime_req = request.GET.get('end_datetime', '')
    variable_id = request.GET.get('variable_id', '')
    cmap = request.GET.get('cmap', 'Spectral_r')
    agg = request.GET.get('agg', "instant")
    vmin = request.GET.get('vmin', 0)
    vmax = request.GET.get('vmax', 30)

    try:
        start_datetime = pytz.UTC.localize(datetime.datetime.strptime(start_datetime_req, '%Y-%m-%dT%H:%M:%S.%fZ'))
        end_datetime = pytz.UTC.localize(datetime.datetime.strptime(end_datetime_req, '%Y-%m-%dT%H:%M:%S.%fZ'))

        start_datetime = start_datetime.astimezone(pytz.timezone(settings.TIMEZONE_NAME))
        end_datetime = end_datetime.astimezone(pytz.timezone(settings.TIMEZONE_NAME))
    except ValueError:
        try:
            start_datetime = pytz.UTC.localize(datetime.datetime.strptime(start_datetime_req, '%Y-%m-%d'))
            end_datetime = pytz.UTC.localize(datetime.datetime.strptime(end_datetime_req, '%Y-%m-%d'))

        except ValueError:
            return JsonResponse({"message": "Invalid date format"}, status=status.HTTP_400_BAD_REQUEST)

    with connection.cursor() as cursor:
        cursor.execute("""
            SELECT a.name,b.symbol
            FROM wx_variable a INNER JOIN wx_unit b ON a.unit_id=b.id
            WHERE a.id=%(variable_id)s;
            """,
                       params={'variable_id': variable_id}
                       )
        variable = cursor.fetchone()

    fig = plt.figure(figsize=(9, 1.5))
    plt.imshow([[2]], origin='lower', cmap=cmap, vmin=vmin, vmax=vmax)
    plt.gca().set_visible(False)
    cax = plt.axes([0.1, 0.2, 0.8, 0.2])
    title = variable[0] + ' (' + variable[1] + ') - ' + start_datetime.strftime("%d/%m/%Y %H:%M:%S")
    if agg != 'instant':
        title += ' to ' + end_datetime.strftime("%d/%m/%Y %H:%M:%S")
        title += ' (' + agg + ')'
    cax.set_title(title)
    plt.colorbar(orientation='horizontal', cax=cax)

    FigureCanvas(fig)
    buf = io.BytesIO()
    plt.savefig(buf, dpi='figure', format='png', transparent=True, bbox_inches='tight')
    plt.close(fig)
    response = HttpResponse(buf.getvalue(), content_type='image/png')

    return response


@csrf_exempt
def InterpolatePostData(request):
    if request.method != 'POST':
        return HttpResponse(status=405)

    stands_llat = settings.SPATIAL_ANALYSIS_INITIAL_LATITUDE
    stands_llon = settings.SPATIAL_ANALYSIS_INITIAL_LONGITUDE
    stands_ulat = settings.SPATIAL_ANALYSIS_FINAL_LATITUDE
    stands_ulon = settings.SPATIAL_ANALYSIS_FINAL_LONGITUDE

    json_body = json.loads(request.body)
    parameters = json_body['parameters']
    vmin = json_body['vmin']
    vmax = json_body['vmax']
    df_climate = json_normalize(json_body['data'])
    try:
        df_climate = df_climate[["station_id", "longitude", "latitude", "measured"]]
    except KeyError:
        return HttpResponse("no-interpolated-data.png")

    gx, gy, img = interpolate_to_grid(
        df_climate["longitude"],
        df_climate["latitude"],
        df_climate["measured"],
        interp_type='cressman',
        minimum_neighbors=int(parameters["minimum_neighbors"]),
        hres=float(parameters["hres"]),
        search_radius=float(parameters["search_radius"]),
        boundary_coords={'west': stands_llon, 'east': stands_ulon, 'south': stands_llat, 'north': stands_ulat}
    )

    fig = plt.figure(frameon=False)
    ax = plt.Axes(fig, [0., 0., 1., 1.])
    ax.set_axis_off()
    fig.add_axes(ax)
    ax.imshow(img, origin='lower', cmap=parameters["cmap"]["value"], vmin=vmin, vmax=vmax)
    for filename in os.listdir('/surface/static/images'):
        try:
            if datetime.datetime.now() - datetime.datetime.strptime(filename.split('_')[0],
                                                                    "%Y-%m-%dT%H:%M:%SZ") > datetime.timedelta(
                minutes=5):
                os.remove('/surface/static/images/' + filename)
        except ValueError:
            continue
    fname = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ_") + str(uuid.uuid4())
    fig.savefig("/surface/static/images/" + fname + ".png", dpi='figure', format='png', transparent=True,
                bbox_inches=Bbox.from_bounds(2, 0, 2.333, 4.013))
    image1 = cv2.imread("/surface/static/images/" + fname + ".png", cv2.IMREAD_UNCHANGED)
    image2 = cv2.imread('/surface/static/images/blz_shape.png', cv2.IMREAD_UNCHANGED)
    image1 = cv2.resize(image1, dsize=(image2.shape[1], image2.shape[0]))
    for i in range(image1.shape[0]):
        for j in range(image1.shape[1]):
            image1[i][j][3] = image2[i][j][3]
    cv2.imwrite("/surface/static/images/" + fname + "-output.png", image1)

    return HttpResponse(fname + "-output.png")


@permission_classes([IsAuthenticated])
def GetImage(request):
    image = request.GET.get('image', None)
    try:
        with open("/surface/static/images/" + image, "rb") as f:
            return HttpResponse(f.read(), content_type="image/jpeg")
    except IOError:
        red = Image.new('RGBA', (1, 1), (255, 0, 0, 0))
        response = HttpResponse(content_type="image/jpeg")
        red.save(response, "JPEG")
        return response

@permission_classes([IsAuthenticated])
def DataCaptureView(request):
    template = loader.get_template('wx/data_capture.html')
    return HttpResponse(template.render({}, request))


class DataExportView(LoginRequiredMixin, TemplateView):
    template_name = "wx/data_export.html"

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)
        context['station_list'] = Station.objects.select_related('profile').all()
        context['variable_list'] = Variable.objects.select_related('unit').all()

        context['station_profile_list'] = StationProfile.objects.all()
        context['station_watershed_list'] = Watershed.objects.all()
        context['station_district_list'] = AdministrativeRegion.objects.all()

        interval_list = Interval.objects.filter(seconds__lte=3600).order_by('seconds')
        context['interval_list'] = interval_list

        return self.render_to_response(context)

# view to display manual upload page
class ManualDataImportView(LoginRequiredMixin, TemplateView):
    '''view for uploading daily data for manual station (file format is xlsx)'''

    template_name = "wx/data/manual_data_import.html"

    # reseting the directory which holds uploaded files before processing
    UPLOAD_DIR = '/data/documents/ingest/manual/check'

    def dispatch(self, request, *args, **kwargs):
        '''Ensure the directory exists before handling a request'''
        if os.path.exists(self.UPLOAD_DIR):  # Check if the directory exists
            shutil.rmtree(self.UPLOAD_DIR)
            logger.info(f"Directory '{self.UPLOAD_DIR}' deleted. (Prep work for Manual Import)")

        try:
            os.makedirs(self.UPLOAD_DIR, exist_ok=True)
            logger.info(f"Created directory '{self.UPLOAD_DIR}'.")
        except PermissionError as e:
            logger.error(f"Permission denied: {e}")
            return HttpResponse("Server error: Unable to create directory.", status=500)

        return super().dispatch(request, *args, **kwargs)

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)

        return self.render_to_response(context)


# retrieves manual data files
@api_view(('GET',))
def ManualDataFiles(request):
    files = []
    for df in ManualStationDataFile.objects.all().order_by('-created_at').values()[:100:1]:

        file_status = df['status_id']

        status_dict = {
            1:"Pending",
            2:"Processing",
            3:"Processed",
            4:"Error",
        }

        def chunk_stations(stations_str):
            stations = stations_str.split("       ")  # Split by multiple spaces
            return [",  ".join(stations[i:i+5]) for i in range(0, len(stations), 5)]

        # Example usage
        formatted_station = chunk_stations(df['stations_list'])

        f = {
            'id': df['id'],
            'upload_date': df['upload_date'],
            'file_name': df['file_name'],
            'status': status_dict[file_status],
            'stations_list': formatted_station,
            'observation': df['observation'],
            'month': df['month'],
            'override_data_on_conflict': "Yes!" if df['override_data_on_conflict'] else "No!",
        }

        files.append(f)

    return Response(files, status=status.HTTP_200_OK)


# delete manual data file
def DeleteManualDataFile(request):
    file_id = request.GET.get('id', None)

    df = ManualStationDataFile.objects.get(pk=file_id)

    df.delete()

    return JsonResponse({}, status=status.HTTP_200_OK)


# recieve files from the manual import page, run some checks and return a success response
@csrf_exempt
def CheckManualImportView(request):
    # print("DATA_UPLOAD_MAX_MEMORY_SIZE:", django.conf.settings.DATA_UPLOAD_MAX_MEMORY_SIZE)
    # print("FILE_UPLOAD_MAX_MEMORY_SIZE:", django.conf.settings.FILE_UPLOAD_MAX_MEMORY_SIZE)
    if request.method == "POST":
        uploaded_files = {}
        unsupported_files = ''
        duplicate_files = ''
        non_existent_stations = []
        UPLOAD_DIR = '/data/documents/ingest/manual/check'
        # dictionary of allowed file types
        allowed_file_types = {
            ".xlsx":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        }

        # Process each file in the request
        for file_name, file_obj in request.FILES.items():
            if file_obj.content_type not in allowed_file_types.values():
                unsupported_files = unsupported_files + file_name + ", "

                continue # skip to the next execution

            # check for any duplicate files and skip
            if file_name in os.listdir(UPLOAD_DIR):
                duplicate_files = duplicate_files + file_name + ", "

                continue # skip to the next execution

            file_path = os.path.join(UPLOAD_DIR, file_name)
            
            # Write file manually
            with open(file_path, "wb") as destination:
                for chunk in file_obj.chunks():  # Write file in chunks
                    destination.write(chunk)

            missing_stations = [] # list holding the stations which do not exist in the database
            excel_df = pd.ExcelFile(file_path) # the excel file into a dataframe
            excel_sheet_names = excel_df.sheet_names # grab all the sheet names

            # Loop through the sheet names in the file 
            for sheet in excel_sheet_names:
                # if a station exists 
                if Station.objects.filter(name=str(sheet)).exists():
                    continue #  continue on with the loop
                else:
                    missing_stations.append(str(sheet)) # add sheet name (station name) to the missing stations list
                    
            if missing_stations:
                os.remove(file_path) # delete the file
                non_existent_stations.append(f"File [{file_name}] contains station(s) which do not exist. Please correct the mistake and re-upload: {', '.join(missing_stations)}")

                continue # skip to the next execution

            file_size = round(os.stat(file_path).st_size / (1024*1024), 4)
            
            uploaded_files[file_name] = file_size # Store file name and size (size in MB)

        return JsonResponse({"uploaded_files": uploaded_files, 
                             "duplicate_files": duplicate_files, 
                             "unsupported_files": unsupported_files, 
                             "non_existent_stations": non_existent_stations}, 
                             status=201
                            )
    
    return JsonResponse({"error": "Invalid request method"}, status=400)


# remove manual data files
@csrf_exempt
def RemoveManualDataFile(request):
    if request.method == 'POST':
        try:
            data = json.loads(request.body)
            file_name = data.get('file')
            remaining_files = {}
            UPLOAD_DIR = '/data/documents/ingest/manual/check'  #Directory path

            # check if the request it to reset the entire folder
            if file_name == 'reset':
                if os.path.exists(UPLOAD_DIR):  # Check if the directory exists
                    shutil.rmtree(UPLOAD_DIR) # remove the directory
                    logger.info(f"Directory '{UPLOAD_DIR}' deleted. (Prep work for Manual Import)")

                try:
                    os.makedirs(UPLOAD_DIR, exist_ok=True)
                    logger.info(f"Created directory '{UPLOAD_DIR}'.")
                except PermissionError as e:
                    logger.error(f"Permission denied: {e}")
                    return JsonResponse({"error": "Unable to create directory."}, status=500)
                
                return JsonResponse({"uploaded_files": remaining_files}, status=201)

            if not file_name:  # Check if file_name was provided
                return JsonResponse({'error': 'A file name is required'}, status=400)

            file_path = os.path.join(UPLOAD_DIR, file_name)

            if os.path.exists(file_path):
                try:
                    os.remove(file_path)
                    logger.info(f"File removed: {file_path}")

                    # Get updated file list
                    # remaining_files = [f for f in os.listdir(UPLOAD_DIR ) if os.path.isfile(os.path.join(UPLOAD_DIR , f))]
                    for f in os.listdir(UPLOAD_DIR):
                        if os.path.isfile(os.path.join(UPLOAD_DIR , f)):
                            path = os.path.join(UPLOAD_DIR , f)
                            file_size = round(os.stat(path).st_size / (1024), 2)
                            remaining_files[f] = file_size # Store file name and size (size in MB)

                    return JsonResponse({"uploaded_files": remaining_files}, status=201)


                except OSError as e: # Handle potential file system errors
                    logger.error(f"Error removing file: {e}")
                    return JsonResponse({'error': f"Error removing {file_name}"}, status=500) # Internal Server Error

            else:
                return JsonResponse({'error': f'File "{file_name}" not found'}, status=404)  # Not Found

        except Exception as e:
            logger.error(f"Error: {e}")
            logger.info(f"this is the file name: {file_name}")
            # logger.info(f"this is the file name: {file_name}")
            return JsonResponse({'error': 'Invalid request data'}, status=400)

    return JsonResponse({'error': 'Invalid request method'}, status=405)


# process the uploaded manual data files
@csrf_exempt
def UploadManualDataFile(request):
    UPLOAD_DIR = '/data/documents/ingest/manual/check'  #Upload Directory path
    PROCESS_DIR = '/data/documents/ingest/manual/process'  #Process Directory path 

    try:
        if request.method == "POST":
            data = json.loads(request.body)
            override_data = data.get('override_on_conflict')

            data_file_id_list=[] # holds ManualStationDataFile id's

            # create PROCESS_DIR if it does not exist
            if os.path.exists(UPLOAD_DIR):
                os.makedirs(PROCESS_DIR, exist_ok=True) # create the process dir if it does not exist

                # loop through files in the UPLOAD DIR and create a New ManualStationDataFile object and move the file to the PROCESS DIR
                for filename in os.listdir(UPLOAD_DIR):
                    source_path = os.path.join(UPLOAD_DIR, filename)

                    # Check if it's a file
                    if os.path.isfile(source_path):
                        # create ManualStationDataFile object
                        new_data_file = ManualStationDataFile.objects.create(file_name=filename, status_id=1, override_data_on_conflict=override_data)

                        destination_path = os.path.join(PROCESS_DIR, str(new_data_file.id) + '.xlsx') # create the destination path based on the file id

                        new_data_file.filepath = destination_path # update the objects file path to be the destination path
                        new_data_file.save()

                        # moving (note that the file name changes)
                        shutil.move(source_path, destination_path)
                        logger.info(f"Moved for manual upload processing: {filename}")

                        data_file_id_list.append(new_data_file.id)

                # call celery task to begin file processing
                tasks.ingest_manual_station_files.delay(data_file_id_list)
                

            else:
                return JsonResponse({'error': 'Error occured during file upload! There are no files to upload'}, status=400)
            

            return JsonResponse({"success": "success"}, status=202)
        else:
            raise
    except Exception as e:
        logger.error(f"Error: {e}")
        return JsonResponse({'error': 'Error occured during file upload!'}, status=400)



class CountryViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = Country.objects.all().order_by("name")
    serializer_class = serializers.CountrySerializer


class UnitViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = Unit.objects.all().order_by("name")
    serializer_class = serializers.UnitSerializer


class DataSourceViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = DataSource.objects.all().order_by("name")
    serializer_class = serializers.DataSourceSerializer


class VariableViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = Variable.objects.all().order_by("name")
    serializer_class = serializers.VariableSerializer


class StationMetadataViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = Station.objects.all()
    serializer_class = serializers.StationMetadataSerializer

    def get_serializer_class(self):
        if self.request.method in ['GET']:
            return serializers.StationSerializerRead
        return serializers.StationMetadataSerializer


class StationViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = Station.objects.all()

    # queryset = Station.objects.all().select_related("country").order_by("name")
    # def put(self, request, *args, **kwargs):
    #     station_object = Station.objects.get()
    #     data = request.data

    #     station_object.save()
    # serializer = serializers.StationSerializerWrite
        

    def get_serializer_class(self):
        if self.request.method in ['GET']:
            return serializers.StationSerializerRead

        return serializers.StationSerializerWrite


class StationSimpleViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = Station.objects.all()
    serializer_class = serializers.StationSimpleSerializer


class StationVariableViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = StationVariable.objects.all().order_by("variable")
    serializer_class = serializers.StationVariableSerializer

    def get_queryset(self):
        queryset = StationVariable.objects.all()

        station_id = self.request.query_params.get('station_id', None)

        if station_id is not None:
            queryset = queryset.filter(station__id=station_id)

        return queryset


class StationProfileViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = StationProfile.objects.all().order_by("name")
    serializer_class = serializers.StationProfileSerializer



class DocumentViewSet(views.APIView):
    permission_classes = (IsAuthenticated,)
    parser_class = (FileUploadParser,)
    queryset = Document.objects.all()
    serializer_class = serializers.DocumentSerializer
    available_decoders = {'HOBO': read_file_hobo, 'TOA5': read_file}
    decoders = Decoder.objects.all().exclude(name='DCP TEXT').exclude(name='NESA')

    def put(self, request, format=None):
        selected_decoder = 'TOA5'

        if 'decoder' in request.data.keys():
            selected_decoder = request.data['decoder']

        serializer = serializers.DocumentSerializer(data=request.data)

        if serializer.is_valid():
            document = serializer.save()
            self.available_decoders[selected_decoder].delay(document.file.path)
            return Response({"message": "FIle uploaded successfully!"}, status=status.HTTP_201_CREATED)

        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    def post(self, request, format=None):
        return self.put(request, format=None)


class AdministrativeRegionViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = AdministrativeRegion.objects.all().order_by("name")
    serializer_class = serializers.AdministrativeRegionSerializer


@api_view(['GET'])
def station_telemetry_data(request, date):
    mock = {
        'temperature': {
            'min': 10,
            'max': 13,
            'avg': 16
        },
        'relativeHumidity': {
            'min': 10,
            'max': 13,
            'avg': 16
        },
        'precipitation': {
            'current': 123
        },
        'windDirection': {
            'current': 'SW'
        },
        'windSpeed': {
            'current': 11,
            'max': 12
        },
        'windGust': {
            'current': 12,
            'max': 11
        },
        'solarRadiation': {
            'current': 12
        },
        'atmosphericPressure': {
            'current': 11
        }
    }

    data = {
        'latest': mock,
        'last24': mock,
        'current': mock,
    }

    return Response(data)


def raw_data_list(request):
    search_type = request.GET.get('search_type', None)
    search_value = request.GET.get('search_value', None)
    search_value2 = request.GET.get('search_value2', None)
    search_date_start = request.GET.get(
        'search_date_start',
        default=(datetime.datetime.now() - datetime.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ')
    )
    search_date_end = request.GET.get(
        'search_date_end',
        default=datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')
    )
    sql_string = ""

    response = {
        'results': [],
        'messages': [],
    }

    try:
        start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%dT%H:%M:%SZ')
        end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%dT%H:%M:%SZ')

    except ValueError:
        message = 'Invalid date format. Expected YYYY-MM-DDTHH:MI:SSZ'
        return JsonResponse(data={"message": message}, status=status.HTTP_400_BAD_REQUEST)

    delta = end_date - start_date

    if delta.days > 8:  # Restrict queries to max seven days
        message = 'Interval between start date and end date is greater than one week.'
        return JsonResponse(data={"message": message}, status=status.HTTP_400_BAD_REQUEST)

    if search_type in ['station', 'stationvariable']:
        try:
            station = Station.objects.get(code=search_value)
        except ObjectDoesNotExist:
            station = Station.objects.get(pk=search_value)
        finally:
            search_value = station.id

    if search_type is not None and search_type == 'variable':
        sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   c.name,
                   c.symbol,
                   a.measured,
                   a.datetime,
                   q.symbol as quality_flag,
                   b.variable_type,
                   a.code
            FROM raw_data a
            JOIN wx_variable b ON a.variable_id=b.id
            LEFT JOIN wx_unit c ON b.unit_id=c.id
            JOIN wx_qualityflag q ON a.quality_flag=q.id
        WHERE b.id = %s 
          AND datetime >= %s 
          AND datetime <= %s
        """

    if search_type is not None and search_type == 'station':
        sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   c.name,
                   c.symbol,
                   a.measured,
                   a.datetime,
                   q.symbol as quality_flag,
                   b.variable_type,
                   a.code
            FROM raw_data a
            JOIN wx_variable b ON a.variable_id=b.id
            LEFT JOIN wx_unit c ON b.unit_id=c.id
            JOIN wx_qualityflag q ON a.quality_flag=q.id
            WHERE station_id=%s AND datetime >= %s AND datetime <= %s"""

    if search_type is not None and search_type == 'stationvariable':
        sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   c.name,
                   c.symbol,
                   a.measured,
                   a.datetime,
                   q.symbol as quality_flag,
                   b.variable_type,
                   a.code
            FROM raw_data a
            JOIN wx_variable b ON a.variable_id=b.id
            LEFT JOIN wx_unit c ON b.unit_id=c.id
            JOIN wx_qualityflag q ON a.quality_flag=q.id
            WHERE station_id=%s AND variable_id=%s AND datetime >= %s AND datetime <= %s"""

    if sql_string:
        sql_string += " ORDER BY datetime"

        with connection.cursor() as cursor:

            if search_type is not None and search_type == 'stationvariable':

                cursor.execute(sql_string, [search_value, search_value2, search_date_start, search_date_end])

            else:

                cursor.execute(sql_string, [search_value, search_date_start, search_date_end])

            rows = cursor.fetchall()

            for row in rows:

                if row[9] is not None and row[9].lower() == 'code':
                    value = row[10]
                else:
                    value = round(row[6], 2)

                obj = {
                    'station': row[0],
                    'date': row[7],
                    'value': value,
                    'variable': {
                        'symbol': row[2],
                        'name': row[3],
                        'unit_name': row[4],
                        'unit_symbol': row[5]
                    }
                }

                response['results'].append(obj)

            if response['results']:
                return JsonResponse(response, status=status.HTTP_200_OK)

    return JsonResponse(data={"message": "No data found."}, status=status.HTTP_404_NOT_FOUND)


def hourly_summary_list(request):
    search_type = request.GET.get('search_type', None)
    search_value = request.GET.get('search_value', None)
    search_value2 = request.GET.get('search_value2', None)
    search_date_start = request.GET.get(
        'search_date_start',
        default=(datetime.datetime.now() - datetime.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ')
    )
    search_date_end = request.GET.get(
        'search_date_end',
        default=datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')
    )
    sql_string = ""

    response = {
        'results': [],
        'messages': [],
    }

    try:
        start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%dT%H:%M:%SZ')
        end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%dT%H:%M:%SZ')

    except ValueError:
        message = 'Invalid date format. Expected YYYY-MM-DDTHH:MI:SSZ'
        return JsonResponse(data={"message": message}, status=status.HTTP_400_BAD_REQUEST)

    delta = end_date - start_date

    if delta.days > 32:  # Restrict queries to max 31 days
        message = 'Interval between start date and end date is greater than one month.'
        return JsonResponse(data={"message": message}, status=status.HTTP_400_BAD_REQUEST)

    if search_type in ['station', 'stationvariable']:
        try:
            station = Station.objects.get(code=search_value)
        except ObjectDoesNotExist:
            station = Station.objects.get(pk=search_value)
        finally:
            search_value = station.id

    if search_type is not None and search_type == 'variable':
        sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   b.sampling_operation_id,
                   c.name,
                   c.symbol,
                   min_value,
                   max_value,
                   avg_value,
                   sum_value,
                   num_records,
                   datetime as data
              FROM hourly_summary a
        INNER JOIN wx_variable b ON a.variable_id=b.id
        INNER JOIN wx_unit c ON b.unit_id=c.id
        WHERE b.id=%s AND datetime >= %s AND datetime <= %s"""

    if search_type is not None and search_type == 'station':
        sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   b.sampling_operation_id,
                   c.name,
                   c.symbol,
                   min_value,
                   max_value,
                   avg_value,
                   sum_value,
                   num_records,
                   datetime as data
              FROM hourly_summary a
        INNER JOIN wx_variable b ON a.variable_id=b.id
        INNER JOIN wx_unit c ON b.unit_id=c.id
             WHERE station_id=%s AND datetime >= %s AND datetime <= %s"""

    if search_type is not None and search_type == 'stationvariable':
        sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   b.sampling_operation_id,
                   c.name,
                   c.symbol,
                   min_value,
                   max_value,
                   avg_value,
                   sum_value,
                   num_records,
                   datetime as data
              FROM hourly_summary a
        INNER JOIN wx_variable b ON a.variable_id=b.id
        INNER JOIN wx_unit c ON b.unit_id=c.id
             WHERE station_id=%s AND variable_id=%s AND datetime >= %s AND datetime <= %s"""

    if sql_string:
        sql_string += " ORDER BY datetime"

        with connection.cursor() as cursor:

            if search_type is not None and search_type == 'stationvariable':

                cursor.execute(sql_string, [search_value, search_value2, search_date_start, search_date_end])

            else:

                cursor.execute(sql_string, [search_value, search_date_start, search_date_end])

            rows = cursor.fetchall()

            for row in rows:

                value = None

                if row[4] in [1, 2]:
                    value = row[9]

                elif row[4] == 3:
                    value = row[7]

                elif row[4] == 4:
                    value = row[8]

                elif row[4] == 6:
                    value = row[10]

                else:
                    value = row[10]

                if value is None:

                    print('variable {} does not have supported sampling operation {}'.format(row[1], row[4]))

                else:

                    obj = {
                        'station': row[0],
                        'date': row[12],
                        'value': round(value, 2),
                        'min': round(row[7], 2),
                        'max': round(row[8], 2),
                        'avg': round(row[9], 2),
                        'sum': round(row[10], 2),
                        'count': round(row[11], 2),
                        'variable': {
                            'symbol': row[2],
                            'name': row[3],
                            'unit_name': row[5],
                            'unit_symbol': row[6],
                        }
                    }

                    response['results'].append(obj)

            if response['results']:
                return JsonResponse(response, status=status.HTTP_200_OK)

    return JsonResponse(data=response)


def daily_summary_list(request):
    search_type = request.GET.get('search_type', None)
    search_value = request.GET.get('search_value', None)
    search_value2 = request.GET.get('search_value2', None)
    search_date_start = request.GET.get(
        'search_date_start',
        default=(datetime.datetime.now() - datetime.timedelta(days=365)).strftime('%Y-%m-%d')
    )
    search_date_end = request.GET.get(
        'search_date_end',
        default=datetime.datetime.now().strftime('%Y-%m-%d')
    )
    sql_string = ""

    response = {
        'results': [],
        'messages': [],
    }

    try:
        start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%d')
        end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%d')

    except ValueError:
        message = 'Invalid date format. Expected YYYY-MM-DD'
        return JsonResponse(data={"message": message}, status=status.HTTP_400_BAD_REQUEST)

    delta = end_date - start_date

    if delta.days > 400:  # Restrict queries to max 400 days
        message = 'Interval between start date and end date is greater than 13 months.'
        return JsonResponse(data={"message": message}, status=status.HTTP_400_BAD_REQUEST)

    if search_type in ['station', 'stationvariable']:
        try:
            station = Station.objects.get(code=search_value)
        except ObjectDoesNotExist:
            station = Station.objects.get(pk=search_value)
        finally:
            search_value = station.id

    if search_type is not None and search_type == 'variable':
        sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   b.sampling_operation_id,
                   c.name,
                   c.symbol,
                   min_value,
                   max_value,
                   avg_value,
                   sum_value,
                   day,
                   num_records
              FROM daily_summary a
        INNER JOIN wx_variable b ON a.variable_id=b.id
        INNER JOIN wx_unit c ON b.unit_id=c.id
        WHERE b.id = %s 
          AND day >= %s 
          AND day <= %s"""

    if search_type is not None and search_type == 'station':
        sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   b.sampling_operation_id,
                   c.name,
                   c.symbol,
                   min_value,
                   max_value,
                   avg_value,
                   sum_value,
                   day,
                   num_records
              FROM daily_summary a
        INNER JOIN wx_variable b ON a.variable_id=b.id
        INNER JOIN wx_unit c ON b.unit_id=c.id
             WHERE station_id=%s AND day >= %s AND day <= %s"""

    if search_type is not None and search_type == 'stationvariable':
        sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   b.sampling_operation_id,
                   c.name,
                   c.symbol,
                   min_value,
                   max_value,
                   avg_value,
                   sum_value,
                   day,
                   num_records
              FROM daily_summary a
        INNER JOIN wx_variable b ON a.variable_id=b.id
        INNER JOIN wx_unit c ON b.unit_id=c.id
             WHERE station_id=%s AND variable_id=%s AND day >= %s AND day <= %s"""

    if sql_string:
        sql_string += " ORDER BY day"

        with connection.cursor() as cursor:

            if search_type is not None and search_type == 'stationvariable':
                cursor.execute(sql_string, [search_value, search_value2, search_date_start, search_date_end])
            else:
                cursor.execute(sql_string, [search_value, search_date_start, search_date_end])

            rows = cursor.fetchall()

            for row in rows:

                value = None

                if row[4] in [1, 2]:
                    value = row[9]

                elif row[4] == 3:
                    value = row[7]

                elif row[4] == 4:
                    value = row[8]

                elif row[4] == 6:
                    value = row[10]

                else:
                    value = row[10]

                if value is not None:

                    obj = {
                        'station': row[0],
                        'date': row[11],
                        'value': round(value, 2),
                        'min': round(row[7], 2),
                        'max': round(row[8], 2),
                        'avg': round(row[9], 2),
                        'total': round(row[10], 2),
                        'count': row[12],
                        'variable': {
                            'symbol': row[2],
                            'name': row[3],
                            'unit_name': row[5],
                            'unit_symbol': row[6],
                        }
                    }

                    response['results'].append(obj)

                else:
                    JsonResponse(data={
                        "message": 'variable {} does not have supported sampling operation {}'.format(row[1], row[4])},
                        status=status.HTTP_400_BAD_REQUEST)

            if response['results']:
                return JsonResponse(response, status=status.HTTP_200_OK)

    return JsonResponse(data=response)


def monthly_summary_list(request):
    search_type = request.GET.get('search_type', None)
    search_value = request.GET.get('search_value', None)
    search_value2 = request.GET.get('search_value2', None)
    search_date_start = request.GET.get(
        'search_date_start',
        default=(datetime.datetime.now() - datetime.timedelta(days=365)).strftime('%Y-%m-%d')
    )
    search_date_end = request.GET.get(
        'search_date_end',
        default=datetime.datetime.now().strftime('%Y-%m-%d')
    )

    sql_string = ""

    response = {
        'count': -999,
        'next': None,
        'previous': None,
        'results': []
    }

    try:
        start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%d')
        end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%d')

    except ValueError:
        message = 'Invalid date format. Expected YYYY-MM-DD'
        return JsonResponse(data={"message": message}, status=status.HTTP_400_BAD_REQUEST)

    if search_type in ['station', 'stationvariable']:
        try:
            station = Station.objects.get(code=search_value)
        except ObjectDoesNotExist:
            station = Station.objects.get(pk=search_value)
        finally:
            search_value = station.id

    if search_type is not None and search_type == 'variable':
        sql_string = """
            SELECT  station_id,
                    variable_id,
                    b.symbol,
                    b.name,
                    b.sampling_operation_id,
                    c.name,
                    c.symbol,
                    min_value,
                    max_value,
                    avg_value,
                    sum_value,
                    date::date,
                    num_records
            FROM monthly_summary a
            JOIN wx_variable b ON a.variable_id=b.id 
            JOIN wx_unit c ON b.unit_id=c.id 
            WHERE b.id = %s
              AND date >= %s 
              AND date <= %s
        """

    if search_type is not None and search_type == 'station':
        sql_string = """
            SELECT  station_id,
                    variable_id,
                    b.symbol, 
                    b.name, 
                    b.sampling_operation_id,
                    c.name, 
                    c.symbol, 
                    min_value,
                    max_value,
                    avg_value,
                    sum_value,
                    date::date,
                    num_records
            FROM monthly_summary a 
            JOIN wx_variable b ON a.variable_id=b.id
            JOIN wx_unit c ON b.unit_id=c.id 
            WHERE station_id = %s 
              AND date >= %s AND date <= %s
        """

    if search_type is not None and search_type == 'stationvariable':
        sql_string = """
            SELECT  station_id,
                    variable_id,
                    b.symbol, 
                    b.name, 
                    b.sampling_operation_id,
                    c.name, 
                    c.symbol, 
                    min_value,
                    max_value,
                    avg_value,
                    sum_value,
                    date::date,
                    num_records
            FROM monthly_summary a 
            JOIN wx_variable b ON a.variable_id=b.id
            JOIN wx_unit c ON b.unit_id=c.id 
            WHERE station_id = %s 
              AND variable_id = %s
              AND date >= %s AND date <= %s
        """

    if sql_string:
        sql_string += " ORDER BY month"

        with connection.cursor() as cursor:

            if search_type is not None and search_type == 'stationvariable':
                cursor.execute(sql_string, [search_value, search_value2, start_date, end_date])
            else:
                cursor.execute(sql_string, [search_value, start_date, end_date])

            rows = cursor.fetchall()

            for row in rows:

                value = None

                if row[4] in [1, 2]:
                    value = row[9]

                elif row[4] == 3:
                    value = row[7]

                elif row[4] == 4:
                    value = row[8]

                elif row[4] == 6:
                    value = row[10]

                else:
                    value = row[10]

                if value is not None:

                    obj = {
                        'station': row[0],
                        'date': row[11],
                        'value': round(value, 2),
                        'min': round(row[7], 2),
                        'max': round(row[8], 2),
                        'avg': round(row[9], 2),
                        'total': round(row[10], 2),
                        'count': row[12],
                        'variable': {
                            'symbol': row[2],
                            'name': row[3],
                            'unit_name': row[5],
                            'unit_symbol': row[6],
                        }
                    }

                    response['results'].append(obj)

                else:
                    JsonResponse(data={
                        "message": 'variable {} does not have supported sampling operation {}'.format(row[1], row[4])},
                        status=status.HTTP_400_BAD_REQUEST)

            if response['results']:
                return JsonResponse(response, status=status.HTTP_200_OK)

    return JsonResponse(data=response)


def yearly_summary_list(request):
    search_type = request.GET.get('search_type', None)
    search_value = request.GET.get('search_value', None)
    search_value2 = request.GET.get('search_value2', None)
    search_date_start = request.GET.get(
        'search_date_start',
        default=(datetime.datetime.now() - datetime.timedelta(days=365)).strftime('%Y-%m-%d')
    )
    search_date_end = request.GET.get(
        'search_date_end',
        default=datetime.datetime.now().strftime('%Y-%m-%d')
    )

    sql_string = ""

    response = {
        'count': -999,
        'next': None,
        'previous': None,
        'results': []
    }

    try:
        start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%d')
        end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%d')

    except ValueError:
        message = 'Invalid date format. Expected YYYY-MM-DD'
        return JsonResponse(data={"message": message}, status=status.HTTP_400_BAD_REQUEST)

    if search_type in ['station', 'stationvariable']:
        try:
            station = Station.objects.get(code=search_value)
        except ObjectDoesNotExist:
            station = Station.objects.get(pk=search_value)
        finally:
            search_value = station.id

    if search_type is not None and search_type == 'variable':
        sql_string = """
            SELECT  station_id,
                    variable_id,
                    b.symbol,
                    b.name,
                    b.sampling_operation_id,
                    c.name,
                    c.symbol,
                    min_value,
                    max_value,
                    avg_value,
                    sum_value,
                    date::date,
                    num_records
            FROM yearly_summary a
            JOIN wx_variable b ON a.variable_id=b.id 
            JOIN wx_unit c ON b.unit_id=c.id 
            WHERE b.id = %s
              AND date >= %s 
              AND date <= %s
        """

    if search_type is not None and search_type == 'station':
        sql_string = """
            SELECT  station_id,
                    variable_id,
                    b.symbol, 
                    b.name, 
                    b.sampling_operation_id,
                    c.name, 
                    c.symbol, 
                    min_value,
                    max_value,
                    avg_value,
                    sum_value,
                    date::date,
                    num_records
            FROM yearly_summary a 
            JOIN wx_variable b ON a.variable_id=b.id
            JOIN wx_unit c ON b.unit_id=c.id 
            WHERE station_id = %s 
              AND date >= %s AND date <= %s
        """

    if search_type is not None and search_type == 'stationvariable':
        sql_string = """
            SELECT  station_id,
                    variable_id,
                    b.symbol, 
                    b.name, 
                    b.sampling_operation_id,
                    c.name, 
                    c.symbol, 
                    min_value,
                    max_value,
                    avg_value,
                    sum_value,
                    date::date,
                    num_records
            FROM yearly_summary a 
            JOIN wx_variable b ON a.variable_id=b.id
            JOIN wx_unit c ON b.unit_id=c.id 
            WHERE station_id = %s 
              AND variable_id = %s
              AND date >= %s AND date <= %s
        """

    if sql_string:
        sql_string += " ORDER BY year"

        with connection.cursor() as cursor:

            if search_type is not None and search_type == 'stationvariable':
                cursor.execute(sql_string, [search_value, search_value2, start_date, end_date])
            else:
                cursor.execute(sql_string, [search_value, start_date, end_date])

            rows = cursor.fetchall()

            for row in rows:

                value = None

                if row[4] in [1, 2]:
                    value = row[9]

                elif row[4] == 3:
                    value = row[7]

                elif row[4] == 4:
                    value = row[8]

                elif row[4] == 6:
                    value = row[10]

                else:
                    value = row[10]

                if value is not None:

                    obj = {
                        'station': row[0],
                        'date': row[11],
                        'value': round(value, 2),
                        'min': round(row[7], 2),
                        'max': round(row[8], 2),
                        'avg': round(row[9], 2),
                        'total': round(row[10], 2),
                        'count': row[12],
                        'variable': {
                            'symbol': row[2],
                            'name': row[3],
                            'unit_name': row[5],
                            'unit_symbol': row[6],
                        }
                    }

                    response['results'].append(obj)

                else:
                    JsonResponse(data={
                        "message": 'variable {} does not have supported sampling operation {}'.format(row[1], row[4])},
                        status=status.HTTP_400_BAD_REQUEST)

            if response['results']:
                return JsonResponse(response, status=status.HTTP_200_OK)

    return JsonResponse(data=response)


@api_view(['GET'])
def station_geo_features(request, lon, lat):
    longitude = float(lon)
    latitude = float(lat)

    altitude = get_altitude(longitude, latitude)

    watershed = get_watershed(longitude, latitude)

    district = get_district(longitude, latitude)

    data = {
        'elevation': altitude,
        'watershed': watershed,
        'country': 'Belize',
        'administrative_region': district,
        'longitude': longitude,
        'latitude': latitude,
    }

    return Response(data)


def get_last24_data(station_id):
    result = []
    max_date = None

    query = """
        SELECT
            last24h.datetime,
            var.name,
            var.symbol,
            var.sampling_operation_id,
            unit.name,
            unit.symbol,
            last24h.min_value,
            last24h.max_value,
            last24h.avg_value,
            last24h.sum_value,
            last24h.latest_value
        FROM
            last24h_summary last24h
        INNER JOIN
            wx_variable var ON last24h.variable_id=var.id
        INNER JOIN
            wx_unit unit ON var.unit_id=unit.id
        WHERE
            last24h.station_id=%s
        ORDER BY var.name"""

    with connection.cursor() as cursor:

        cursor.execute(query, [station_id])

        rows = cursor.fetchall()

        for row in rows:

            value = None

            if row[3] == 1:
                value = row[10]

            elif row[3] == 2:
                value = row[8]

            elif row[3] == 3:
                value = row[6]

            elif row[3] == 4:
                value = row[7]

            elif row[3] == 6:
                value = row[9]

            if value is None:
                print('variable {} does not have supported sampling operation {}'.format(row[1], row[3]))

            obj = {
                'value': value,
                'variable': {
                    'name': row[1],
                    'symbol': row[2],
                    'unit_name': row[4],
                    'unit_symbol': row[5]
                }
            }
            result.append(obj)

        max_date = cache.get('last24h_summary_last_run', None)

    return result, max_date


def get_latest_data(station_id):
    result = []
    max_date = None

    query = """
        SELECT CASE WHEN var.variable_type ilike 'code' THEN latest.last_data_code ELSE latest.last_data_value::varchar END as value,
               latest.last_data_datetime,
               var.name,
               var.symbol,
               unit.name,
               unit.symbol
        FROM wx_stationvariable latest
        INNER JOIN wx_variable var ON latest.variable_id=var.id
        LEFT JOIN wx_unit unit ON var.unit_id=unit.id
        WHERE latest.station_id=%s 
          AND latest.last_data_value is not null
          AND latest.last_data_datetime = ( SELECT MAX(most_recent.last_data_datetime)
                                            FROM wx_stationvariable most_recent
                                            WHERE most_recent.station_id=latest.station_id 
                                                AND most_recent.last_data_value is not null)
        ORDER BY var.name
        """

    with connection.cursor() as cursor:

        cursor.execute(query, [station_id])

        rows = cursor.fetchall()

        for row in rows:
            obj = {
                'value': row[0],
                'variable': {
                    'name': row[2],
                    'symbol': row[3],
                    'unit_name': row[4],
                    'unit_symbol': row[5]
                }
            }
            result.append(obj)

        if rows:
            max_date = rows[-1][1]

    return result, max_date


def get_current_data(station_id):
    result = []
    max_date = None
    parameter_timezone = pytz.timezone(settings.TIMEZONE_NAME)
    today = datetime.datetime.now().astimezone(parameter_timezone).date()

    query = """
        SELECT current.day,
               var.name,
               var.symbol,
               var.sampling_operation_id,
               unit.name,
               unit.symbol,
               current.min_value,
               current.max_value,
               current.avg_value,
               current.sum_value
        FROM daily_summary current
        INNER JOIN wx_variable var ON current.variable_id=var.id
        INNER JOIN wx_unit unit ON var.unit_id=unit.id
        WHERE current.station_id=%s and current.day=%s
        ORDER BY current.day, var.name
    """

    with connection.cursor() as cursor:

        cursor.execute(query, [station_id, today])

        rows = cursor.fetchall()

        for row in rows:

            value = None

            if row[3] in (1, 2):
                value = row[8]

            elif row[3] == 3:
                value = row[6]

            elif row[3] == 4:
                value = row[7]

            elif row[3] == 6:
                value = row[9]

            if value is None:
                print('variable {} does not have supported sampling operation {}'.format(row[1], row[3]))

            obj = {
                'value': value,
                'variable': {
                    'name': row[1],
                    'symbol': row[2],
                    'unit_name': row[4],
                    'unit_symbol': row[5]
                }
            }
            result.append(obj)

        max_date = cache.get('daily_summary_last_run', None)

    return result, max_date


@api_view(['GET'])
def livedata(request, code):
    try:
        station = Station.objects.get(code=code)
    except ObjectDoesNotExist as e:
        station = Station.objects.get(pk=code)
    finally:
        id = station.id

    past24h_data, past24h_max_date = get_last24_data(station_id=id)
    latest_data, latest_max_date = get_latest_data(station_id=id)
    current_data, current_max_date = get_current_data(station_id=id)

    station_data = serializers.StationSerializerRead(station).data

    return Response(
        {
            'station': station_data,
            'station_name': station.name,
            'station_id': station.id,
            'past24h': past24h_data,
            'past24h_last_update': past24h_max_date,
            'latest': latest_data,
            'latest_last_update': latest_max_date,
            'currentday': current_data,
            'currentday_last_update': current_max_date,
        }
        , status=status.HTTP_200_OK)


class WatershedList(generics.ListAPIView):
    permission_classes = (IsAuthenticated,)
    serializer_class = serializers.WatershedSerializer
    queryset = Watershed.objects.all().order_by("watershed")


class StationCommunicationList(generics.ListAPIView):
    permission_classes = (IsAuthenticated,)
    serializer_class = serializers.StationCommunicationSerializer
    queryset = StationCommunication.objects.all()


class DecoderList(generics.ListAPIView):
    permission_classes = (IsAuthenticated,)
    serializer_class = serializers.DecoderSerializer
    queryset = Decoder.objects.all().order_by("name")


class QualityFlagList(viewsets.ReadOnlyModelViewSet):
    permission_classes = (IsAuthenticated,)
    serializer_class = serializers.QualityFlagSerializer
    queryset = QualityFlag.objects.all().order_by("name")


def qc_list(request):
    if request.method == 'GET':
        station_id = request.GET.get('station_id', None)
        variable_id = request.GET.get('variable_id', None)
        start_date = request.GET.get('start_date', None)
        end_date = request.GET.get('end_date', None)

        if station_id is None:
            JsonResponse(data={"message": "'station_id' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if variable_id is None:
            JsonResponse(data={"message": "'variable_id' parameter cannot be null."},
                         status=status.HTTP_400_BAD_REQUEST)

        sql_string = ""
        where_parameters = [station_id, variable_id]

        response = {
            'count': -999,
            'next': None,
            'previous': None,
            'results': []
        }

        sql_string = """SELECT value.datetime
                            ,value.measured
                            ,value.consisted
                            ,value.quality_flag
                            ,value.manual_flag
                            ,value.station_id
                            ,value.variable_id
                            ,value.remarks
                            ,value.ml_flag
                        FROM raw_data as value
                        WHERE value.station_id=%s
                        AND value.variable_id=%s
                    """

        if start_date is not None and end_date is not None:
            where_parameters.append(start_date)
            where_parameters.append(end_date)
            sql_string += " AND value.datetime >= %s AND value.datetime <= %s"

        elif start_date is not None:
            where_parameters.append(start_date)
            sql_string += " AND value.datetime >= %s"

        elif end_date is not None:
            where_parameters.append(end_date)
            sql_string += " AND %s >= value.datetime "

        sql_string += " ORDER BY value.datetime "
        with connection.cursor() as cursor:

            cursor.execute(sql_string, where_parameters)
            rows = cursor.fetchall()

            for row in rows:
                obj = {
                    'datetime': row[0],
                    'measured': row[1],
                    'consisted': row[2],
                    'automatic_flag': row[3],
                    'manual_flag': row[4],
                    'station_id': row[5],
                    'variable_id': row[6],
                    'remarks': row[7],
                    'ml_flag': row[8],
                }

                response['results'].append(obj)

        return JsonResponse(response)

    if request.method == 'PATCH':
        station_id = request.GET.get('station_id', None)
        variable_id = request.GET.get('variable_id', None)
        req_datetime = request.GET.get('datetime', None)

        if station_id is None:
            JsonResponse(data={"message": "'station_id' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if variable_id is None:
            JsonResponse(data={"message": "'variable_id' parameter cannot be null."},
                         status=status.HTTP_400_BAD_REQUEST)

        if req_datetime is None:
            JsonResponse(data={"message": "'datetime' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        try:
            station_id = int(station_id)
            variable_id = int(variable_id)
            req_datetime = datetime.datetime.strptime(req_datetime, '%Y-%m-%dT%H:%M:%SZ')
        except ValueError:
            JsonResponse(data={"message": "Invalid parameter type."}, status=status.HTTP_400_BAD_REQUEST)

        body = json.loads(request.body.decode('utf-8'))
        query_parameters = []
        sql_columns_to_update = []

        if 'manual_flag' in body:
            try:
                query_parameters.append(parse_int_value(body['manual_flag']))
                sql_columns_to_update.append(' manual_flag=%s ')
            except ValueError:
                return JsonResponse({'message': 'Wrong manual flag value type.'}, status=status.HTTP_400_BAD_REQUEST)

        if 'consisted' in body:
            try:
                query_parameters.append(parse_float_value(body['consisted']))
                sql_columns_to_update.append(' consisted=%s ')
            except ValueError:
                return JsonResponse({'message': 'Wrong consisted value type. Please inform a float value.'},
                                    status=status.HTTP_400_BAD_REQUEST)

        if 'remarks' in body:
            try:
                query_parameters.append(body['remarks'])
                sql_columns_to_update.append(' remarks=%s ')
            except ValueError:
                return JsonResponse({'message': 'Wrong remarks value type. Please inform a text value.'},
                                    status=status.HTTP_400_BAD_REQUEST)

        if not sql_columns_to_update:
            JsonResponse(data={"message": "You must send 'manual_flag', 'consisted' or 'remarks' data to update."},
                         status=status.HTTP_400_BAD_REQUEST)

        if query_parameters:
            query_parameters.append(req_datetime)
            query_parameters.append(station_id)
            query_parameters.append(variable_id)
            sql_query = f"UPDATE raw_data SET {', '.join(sql_columns_to_update)} WHERE datetime=%s AND station_id=%s AND variable_id=%s"

            station = Station.objects.get(pk=station_id)
            with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
                with conn.cursor() as cursor:
                    cursor.execute(sql_query, query_parameters)

                    now = datetime.datetime.now()
                    cursor.execute("""
                        INSERT INTO wx_hourlysummarytask (station_id, datetime, updated_at, created_at)
                        VALUES (%s, %s, %s, %s)
                        ON CONFLICT DO NOTHING
                    """, (station_id, req_datetime, now, now))

                    station_timezone = pytz.UTC
                    if station.utc_offset_minutes is not None:
                        station_timezone = pytz.FixedOffset(station.utc_offset_minutes)

                    date = req_datetime.astimezone(station_timezone).date()
                    cursor.execute("""
                        INSERT INTO wx_dailysummarytask (station_id, date, updated_at, created_at)
                        VALUES (%s, %s, %s, %s)
                        ON CONFLICT DO NOTHING
                    """, (station_id, date, now, now))

                    cursor.execute(sql_query, query_parameters)

                conn.commit()

            return JsonResponse({}, status=status.HTTP_200_OK)
        return JsonResponse({'message': "There is no 'manual_flag' or 'consisted' fields in the json request."},
                            status=status.HTTP_400_BAD_REQUEST)

    return JsonResponse({'message': 'Only the GET and PATCH methods is allowed.'}, status=status.HTTP_400_BAD_REQUEST)


@csrf_exempt
def interpolate_endpoint(request):
    request_date = request.GET.get('request_date', None)
    variable_id = request.GET.get('variable_id', None)
    data_type = request.GET.get('data_type', None)

    sql_string = ''
    where_parameters = [variable_id, request_date]

    if data_type == 'daily':
        sql_string = """
            SELECT station.latitude
                ,station.longitude
                ,daily.avg_value
            FROM daily_summary as daily
            INNER JOIN wx_station as station ON daily.station_id=station.id
            WHERE daily.variable_id=%s and daily.day=%s
            ORDER BY daily.day
        """

    elif data_type == 'hourly':

        sql_string = """
            SELECT station.latitude
                  ,station.longitude
                  ,hourly.avg_value
            FROM hourly_summary as hourly
            INNER JOIN wx_station as station ON hourly.station_id=station.id
            WHERE hourly.variable_id=%s and hourly.datetime=%s
            ORDER BY hourly.datetime
        """

    elif data_type == 'monthly':
        sql_string = """
            SELECT station.latitude
                  ,station.longitude
                  ,monthly.avg_value
            FROM monthly_summary as monthly
            INNER JOIN wx_station as station ON monthly.station_id=station.id
            WHERE monthly.variable_id=%s and to_date(concat(lpad(monthly.year::varchar(4),4,'0'), lpad(monthly.month::varchar(2),2,'0'), '01'), 'YYYYMMDD')=date_trunc('month',TIMESTAMP %s)
            ORDER BY monthly.year, monthly.month
        """

    if sql_string and where_parameters:
        query_result = []
        with connection.cursor() as cursor:
            cursor.execute(sql_string, where_parameters)
            rows = cursor.fetchall()

            for row in rows:
                obj = {
                    'station__latitude': row[0],
                    'station__longitude': row[1],
                    'value': row[2],
                }

                query_result.append(obj)

            if not query_result:
                return JsonResponse({'message': 'No data found.'}, status=status.HTTP_400_BAD_REQUEST)

            return HttpResponse(get_interpolation_image(query_result), content_type="image/jpeg")

    return JsonResponse({'message': 'Missing parameters.'}, status=status.HTTP_400_BAD_REQUEST)


@csrf_exempt
def capture_forms_values_get(request):
    request_month = request.GET.get('request_month', None)
    station_id = request.GET.get('station_id', None)
    variable_id = request.GET.get('variable_id', None)

    sql_string = """
        select to_char(date.day, 'DD')
              ,to_char(date.day, 'HHAM')
              ,values.measured
              ,%s
              ,%s
              ,date.day
        from ( select generate_series(to_date(%s, 'YYYY-MM') + interval '6 hours', (to_date(%s, 'YYYY-MM') + interval '1 month -1 second'), '12 hours') as day ) date
        LEFT JOIN raw_data as values ON date.day=values.datetime and values.station_id=%s and values.variable_id=%s
        ORDER BY date.day
    """
    where_parameters = [station_id, variable_id, request_month, request_month, station_id, variable_id]

    with connection.cursor() as cursor:
        cursor.execute(sql_string, where_parameters)
        rows = cursor.fetchall()

        days = rows

        days = {}
        for row in rows:
            obj = {
                'value': row[2],
                'station_id': row[3],
                'variable_id': row[4],
                'datetime': row[5],
            }

            if row[0] not in days.keys():
                days[row[0]] = {}

            days[row[0]][row[1]] = obj

        full_list = []
        for day in days.keys():
            line = {}
            for obj in days[day]:
                line[obj] = days[day][obj]
            full_list.append(line)

        if not days:
            return JsonResponse({'message': 'No data found.'}, status=status.HTTP_400_BAD_REQUEST)

        return JsonResponse({'next': None, 'results': full_list}, safe=False, status=status.HTTP_200_OK)

    return JsonResponse({'message': 'Missing parameters.'}, status=status.HTTP_400_BAD_REQUEST)


'''
@csrf_exempt
def capture_forms_values_patch(request):
    if request.method == 'PATCH':

        body = json.loads(request.body.decode('utf-8'))

        conn = psycopg2.connect(settings.SURFACE_CONNECTION_STRING)
        with conn.cursor() as cursor:
            cursor.executemany(
               """
                    INSERT INTO raw_data(datetime, station_id, variable_id, measured) VALUES(%(datetime)s, %(station_id)s, %(variable_id)s, %(value)s::double precision)
                    ON CONFLICT (datetime, station_id, variable_id)
                    DO UPDATE
                    SET measured = %(value)s
                """, body)

        conn.commit()
        conn.close()

        return JsonResponse({}, status=status.HTTP_200_OK)
    return JsonResponse({'message':'Only the GET and PATCH methods is allowed.'}, status=status.HTTP_400_BAD_REQUEST)
'''


@csrf_exempt
def capture_forms_values_patch(request):
    error_flag = False
    if request.method == 'PATCH':

        body = json.loads(request.body.decode('utf-8'))

        with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
            with conn.cursor() as cursor:
                for rec in body:
                    try:
                        if not rec['value']:
                            cursor.execute(
                                """ DELETE FROM raw_data WHERE datetime=%(datetime)s and station_id=%(station_id)s and variable_id=%(variable_id)s """,
                                rec)
                        else:
                            valor = float(rec['value'])

                            cursor.execute(
                                """
                                    INSERT INTO raw_data(datetime, station_id, variable_id, measured) VALUES(%(datetime)s, %(station_id)s, %(variable_id)s, %(value)s::double precision)
                                    ON CONFLICT (datetime, station_id, variable_id)
                                    DO UPDATE
                                    SET measured = %(value)s
                                """, rec)
                    except (ValueError, psycopg2.errors.InvalidTextRepresentation):
                        error_flag = True

            conn.commit()

        if error_flag:
            return JsonResponse({'message': 'Some data was bad formated, please certify that the input is numeric.'},
                                status=status.HTTP_200_OK)

        return JsonResponse({}, status=status.HTTP_200_OK)
    return JsonResponse({'message': 'Only the GET and PATCH methods is allowed.'}, status=status.HTTP_400_BAD_REQUEST)


class StationOscarExportView(LoginRequiredMixin, ListView):
    model = Station
    template_name = 'wx/station_oscar_export.html'

    def get_queryset(self):
        # filter out all stations which don't have a wigos, wmo_region, and reporting_status
        oscar_stations = Station.objects.filter(
                                                wigos__isnull=False,
                                                wmo_region__isnull=False,
                                                reporting_status__isnull=False,
                                                wmo_station_type__isnull=False
                                            )
        
        # filter out all stations which are already in OSCAR into a list
        export_ready_stations = [obj for obj in oscar_stations if not exso.check_station(obj.wigos, pyoscar.OSCARClient())]

        # extract primary keys of the filtered objects
        filtered_ids = [obj.id for obj in export_ready_stations]

        # convert filtered list back to a queryset
        filtered_queryset = Station.objects.filter(id__in=filtered_ids)

        return filtered_queryset
    

    def post(self, request, *args, **kwargs):

        try:
            # run station export task
            oscar_status_msg = export_station_to_oscar(request)

            # run slight text formating on the status messages
            for station_info in oscar_status_msg:
                if station_info.get('logs'):
                    station_info['logs'] = station_info['logs'].replace('\n', '<br/>')

                elif station_info.get('description'):
                    station_info['description'] = station_info['description'].replace('\n', '<br/>')

            # get the names of the stations with status messages
            status_station_names = list(Station.objects.filter(wigos__in=request.POST.getlist('selected_ids[]')).values_list('name', flat=True))

            response_data = {
                'success': True,
                'oscar_status_msg': oscar_status_msg,
                'status_station_names': status_station_names,
            }

        except Exception as e:
            response_data = {
                'success': False,
                'oscar_status_msg': [{'code': 406, 'description': 'An error occured when attempting to add stations to OSCAR'}],
                'message': f'An error occured when attempting to add stations to OSCAR: {e}',
            }
            
        return JsonResponse(response_data)

    
class StationListView(LoginRequiredMixin, ListView):
    model = Station


class StationDetailView(LoginRequiredMixin, DetailView):
    model = Station
    template_name = 'wx/station_detail.html'  # Use the appropriate template
    context_object_name = 'station'

    # Define the same layout as in the UpdateView
    layout = Layout(
        Fieldset('Station Information',
                 Row('latitude', 'longitude'),
                 Row('name', 'alias_name'),
                 Row('code', 'wigos'),
                 Row('begin_date', 'end_date', 'relocation_date'),
                 Row('wmo', 'reporting_status'),
                 Row('is_active', 'is_automatic', 'is_synoptic', 'international_exchange'),
                 Row('synoptic_code', 'synoptic_type'),
                 Row('network', 'wmo_station_type'),
                 Row('profile', 'communication_type'),
                 Row('elevation', 'country'),
                 Row('region', 'watershed'),
                 Row('wmo_region', 'utc_offset_minutes'),
                 Row('wmo_station_plataform', 'data_type'),
                 Row('observer', 'organization'),
                ),
        Fieldset('Local Environment',
                 Row('local_land_use'),
                 Row('soil_type'),
                 Row('site_description'),
                ),
        Fieldset('Instrumentation and Maintenance'),
        Fieldset('Observing Practices'),
        Fieldset('Data Processing'),
        Fieldset('Historical Events'),
        Fieldset('Other Metadata',
                 Row('hydrology_station_type', 'ground_water_province'),
                 Row('existing_gauges', 'flow_direction_at_station'),
                 Row('flow_direction_above_station', 'flow_direction_below_station'),
                 Row('bank_full_stage', 'bridge_level'),
                 Row('temporary_benchmark', 'mean_sea_level'),
                 Row('river_code', 'river_course'),
                 Row('catchment_area_station', 'river_origin'),
                 Row('easting', 'northing'),
                 Row('river_outlet', 'river_length'),
                 Row('z', 'land_surface_elevation'),
                 Row('top_casing_land_surface', 'casing_diameter'),
                 Row('screen_length', 'depth_midpoint'),
                 Row('casing_type', 'datum'),
                 Row('zone')
                 )
        )

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        
        # Disable all fields
        station_form = StationForm(instance=self.object)
        for field in station_form.fields:
            station_form.fields[field].widget.attrs['disabled'] = 'disabled'
            # Add a custom class to apply the dashed border via CSS
            station_form.fields[field].widget.attrs['class'] = 'dashed-border-field'

        context['form'] = station_form
        context['station_name'] = Station.objects.values('pk', 'name')  # Fetch only pk and name
        # context['layout'] = self.layout
        return context


class StationCreate(LoginRequiredMixin, SuccessMessageMixin, CreateView):
    model = Station

    success_message = "%(name)s was created successfully"
    # form_class = StationCreateForm(instance=self.object)
    form_class = StationForm

    layout = Layout(
        Fieldset('SURFACE Requirements',
                 Row('latitude', 'longitude'),
                 Row('name', 'code'),
                 Row('is_active', 'is_automatic', 'is_synoptic', 'international_exchange'),
                 Row('synoptic_code', 'synoptic_type'),
                 Row('region', 'elevation'),
                 Row('country', 'communication_type'),
                 Row('utc_offset_minutes', 'begin_date'),
                 ),
        Fieldset('Additional Options',
                #  Row('wigos'),
                 Row('wigos_part_1', 'wigos_part_2', 'wigos_part_3', 'wigos_part_4'),
                 Row('wmo_region'),
                 Row('wmo_station_type', 'reporting_status'),
                 ),
        Fieldset('OSCAR Specific Settings',
                #  Row(''),
                ),
        Fieldset('WIS2BOX Specific Settings',
                #  Row(''),
                )
        # Fieldset('Other information',
        #          Row('alias_name', 'observer'),
        #          Row('wmo', 'organization'),
        #          Row('profile', 'data_source'),
        #          Row('end_date', 'local_land_use'),
        #          Row('soil_type', 'station_details'),
        #          Row('site_description', 'alternative_names')
        #          ),
        # Fieldset('Hydrology information',
        #          Row('hydrology_station_type', 'ground_water_province'),
        #          Row('existing_gauges', 'flow_direction_at_station'),
        #          Row('flow_direction_above_station', 'flow_direction_below_station'),
        #          Row('bank_full_stage', 'bridge_level'),
        #          Row('temporary_benchmark', 'mean_sea_level'),
        #          Row('river_code', 'river_course'),
        #          Row('catchment_area_station', 'river_origin'),
        #          Row('easting', 'northing'),
        #          Row('river_outlet', 'river_length'),
        #          Row('z', 'land_surface_elevation'),
        #          Row('top_casing_land_surface', 'casing_diameter'),
        #          Row('screen_length', 'depth_midpoint'),
        #          Row('casing_type', 'datum'),
        #          Row('zone')
        #          )
    )

    # Override dispatch to initialize variables
    def dispatch(self, request, *args, **kwargs):
        # Initialize your instance variable oscar_error_message
        self.oscar_error_msg = ""
        self.is_oscar_error_msg = False
        
        # Call the parent class's dispatch method to ensure the default behavior is preserved
        return super().dispatch(request, *args, **kwargs)
    

    # ################
    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)

        # context['watersheds'] = Watershed.objects.all()
        # context['regions'] = AdministrativeRegion.objects.all()

        # to show station management buttons beneath the title
        context['is_create'] = True

        return context


    # form_valid function
    def form_valid(self, form):

        # retrieve api token and wigos_id
        oscar_api_token = self.request.POST.get('oscar_api_token')

        station_wigos_id = [f"{str(form.cleaned_data['wigos_part_1'])}-{str(CountryISOCode.objects.filter(name=form.cleaned_data['wigos_part_2']).values_list('notation', flat=True).first())}-{str(form.cleaned_data['wigos_part_3'])}-{str(form.cleaned_data['wigos_part_4'])}"]

        if oscar_api_token:
            try:
                # run station export task
                oscar_response_dict = export_station_to_oscar_wigos(station_wigos_id, oscar_api_token, form.cleaned_data)

                # check if station was succesfully added to OSCAR or not
                oscar_check = self.check_oscar_push(oscar_response_dict)

                # if oscar push was unsuccessful
                if not oscar_check[0]:

                    # get the error message (why the oscar push failed)
                    self.oscar_error_msg = oscar_check[1]['error_message']
                    # oscar has recieved failed and therefore recieved an error message
                    self.is_oscar_error_msg = True

                    # execute the form_invalid option
                    return self.form_invalid(form)

            except Exception as e:

                print(f"An error occured when attempting to add a station to OSCAR during station create!\nError: {e}")

                self.oscar_error_msg = 'An error occured when attempting to add a station to OSCAR during station creation!'

                self.is_oscar_error_msg = True

                return self.form_invalid(form)

        return super().form_valid(form)


    def form_invalid(self, form):
        # default behavior catches form errors
        response = super().form_invalid(form)

        response.context_data['oscar_error_msg'] = self.oscar_error_msg
        response.context_data['is_oscar_error_msg'] = self.is_oscar_error_msg

        return response


    # fxn to check if station was successfully added to oscar
    def check_oscar_push(self, oscar_response):
        oscar_response_message = {'error_message': ""}

        if oscar_response.get('code'):
            if oscar_response['code'] == 401:
                oscar_response_message['error_message'] = "Incorrect API token!\nTo be able to access OSCAR a valid API token is required.\nEnter the correct API token or please contact OSCAR service desk!"
            elif oscar_response['code'] == 412:
                oscar_response_message['error_message'] = oscar_response['description']
            else:
                oscar_response_message['error_message'] = "An error occured when attempting to add a station to OSCAR during station creation!"


        # return true is oscar push was successful
        elif oscar_response.get('xmlStatus'):

            if  oscar_response['xmlStatus'] == 'SUCCESS':
                return [True]
            else:
                oscar_response_message['error_message'] = oscar_response['logs']
        
        # otherwise return false
        return [False, oscar_response_message]



class StationUpdate(LoginRequiredMixin, SuccessMessageMixin, UpdateView):
    template_name = "wx/station_update.html"
    model = Station
    success_message = "%(name)s was updated successfully"
    form_class = StationForm

    layout = Layout(
        Fieldset('Station Information',
                 Row('latitude', 'longitude'),
                 Row('name', 'alias_name'),
                 Row('code', 'wigos'),
                 Row('begin_date', 'end_date', 'relocation_date'),
                 Row('wmo', 'reporting_status'),
                 Row('is_active', 'is_automatic', 'is_synoptic', 'international_exchange'),
                 Row('synoptic_code', 'synoptic_type'),
                 Row('network', 'wmo_station_type'),
                 Row('profile', 'communication_type'),
                 Row('elevation', 'country'),
                 Row('region', 'watershed'),
                 Row('wmo_region', 'utc_offset_minutes'),
                 Row('wmo_station_plataform', 'data_type'),
                 Row('observer', 'organization'),
                ),
        Fieldset('Local Environment',
                 Row('local_land_use'),
                 Row('soil_type'),
                 Row('site_description'),
                ),
        Fieldset('Instrumentation and Maintenance',
                #  Row(''),
                ),
        Fieldset('Observing Practices',
                #  Row(''),
                ),
        Fieldset('Data Processing',
                #  Row(''),
                ),
        Fieldset('Historical Events',
                #  Row(''),
                ),
        Fieldset('Other Metadata',
                 Row('hydrology_station_type', 'ground_water_province'),
                 Row('existing_gauges', 'flow_direction_at_station'),
                 Row('flow_direction_above_station', 'flow_direction_below_station'),
                 Row('bank_full_stage', 'bridge_level'),
                 Row('temporary_benchmark', 'mean_sea_level'),
                 Row('river_code', 'river_course'),
                 Row('catchment_area_station', 'river_origin'),
                 Row('easting', 'northing'),
                 Row('river_outlet', 'river_length'),
                 Row('z', 'land_surface_elevation'),
                 Row('top_casing_land_surface', 'casing_diameter'),
                 Row('screen_length', 'depth_midpoint'),
                 Row('casing_type', 'datum'),
                 Row('zone')
                 )
    #     Fieldset('Editing station',
    #              Row('latitude', 'longitude'),
    #              Row('name', 'is_active'),
    #              Row('alias_name', 'is_automatic'),
    #              Row('code', 'profile'),
    #              Row('wmo', 'organization'),
    #              Row('wigos', 'observer'),
    #              Row('begin_date', 'data_source'),
    #              Row('end_date', 'communication_type')
    #              ),
    #     Fieldset('Other information',
    #              Row('elevation', 'watershed'),
    #              Row('country', 'region'),
    #              Row('utc_offset_minutes', 'local_land_use'),
    #              Row('soil_type', 'station_details'),
    #              Row('site_description', 'alternative_names')
    #              ),
    #     Fieldset('Hydrology information',
    #              Row('hydrology_station_type', 'ground_water_province'),
    #              Row('existing_gauges', 'flow_direction_at_station'),
    #              Row('flow_direction_above_station', 'flow_direction_below_station'),
    #              Row('bank_full_stage', 'bridge_level'),
    #              Row('temporary_benchmark', 'mean_sea_level'),
    #              Row('river_code', 'river_course'),
    #              Row('catchment_area_station', 'river_origin'),
    #              Row('easting', 'northing'),
    #              Row('river_outlet', 'river_length'),
    #              Row('z', 'land_surface_elevation'),
    #              Row('top_casing_land_surface', 'casing_diameter'),
    #              Row('screen_length', 'depth_midpoint'),
    #              Row('casing_type', 'datum'),
    #              Row('zone')
    #              )
        )

       
    # passing context to display menu buttons beneat the title
    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)

        context['is_update'] = True

        return context


@api_view(['GET'])
def MonthlyFormLoad(request):
    try:
        start_date = datetime.datetime.strptime(request.GET['date'], '%Y-%m')
        station_id = int(request.GET['station'])
    except ValueError as e:
        return JsonResponse({}, status=status.HTTP_400_BAD_REQUEST)
    except Exception as e:
        return JsonResponse({}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

    station = Station.objects.get(id=station_id)
    datetime_offset = pytz.FixedOffset(station.utc_offset_minutes)
    end_date = start_date.replace(month=start_date.month + 1) - datetime.timedelta(days=1)

    with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
        with conn.cursor() as cursor:
            cursor.execute(
                f"""
                    SELECT (datetime + interval '{station.utc_offset_minutes} minutes') at time zone 'utc'
                          ,variable_id
                          ,measured
                    FROM raw_data
                    WHERE station_id = %(station_id)s
                      AND datetime >= %(start_date)s 
                      AND datetime <= %(end_date)s
                """,
                {
                    'start_date': start_date,
                    'end_date': end_date,
                    'station_id': station_id
                })

            response = cursor.fetchall()

        conn.commit()

    return JsonResponse(response, status=status.HTTP_200_OK, safe=False)


@api_view(['POST'])
def MonthlyFormUpdate(request):
    with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
        records_list = []

        station_id = int(request.data['station'])
        station = Station.objects.get(id=station_id)
        first_day = datetime.datetime(year=int(request.data['date']['year']), month=int(request.data['date']['month']),
                                      day=1)

        now_utc = datetime.datetime.now().astimezone(pytz.UTC)
        datetime_offset = pytz.FixedOffset(station.utc_offset_minutes)

        days_in_month = (first_day.replace(month=first_day.month + 1) - datetime.timedelta(days=1)).day

        for day in range(0, days_in_month):
            data = request.data['table'][day]
            data_datetime = first_day.replace(day=day + 1)
            data_datetime = datetime_offset.localize(data_datetime)

            if data_datetime <= now_utc:
                for variable_id, value in data.items():
                    if value is None:
                        value = settings.MISSING_VALUE

                    records_list.append((
                        station_id, variable_id, 86400, data_datetime, value, 1, None, None, None, None,
                        None, None, None, None, False, None, None, None))

    insert_raw_data_pgia.insert(raw_data_list=records_list, date=first_day, station_id=station_id,
                                override_data_on_conflict=True, utc_offset_minutes=station.utc_offset_minutes)
    return JsonResponse({}, status=status.HTTP_200_OK)


class StationDelete(LoginRequiredMixin, DeleteView):
    model = Station
    fields = ['code', 'name', 'profile', ]

    def get_success_url(self):
        return reverse('stations-list')


class StationFileList(LoginRequiredMixin, ListView):
    model = StationFile

    def get_queryset(self):
        queryset = StationFile.objects.filter(station__id=self.kwargs.get('pk'))
        return queryset

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        station = Station.objects.get(pk=self.kwargs.get(
            'pk'))  # the self.kwargs is different from **kwargs, and gives access to the named url parameters
        context['station'] = station
        return context


class StationFileCreate(LoginRequiredMixin, SuccessMessageMixin, CreateView):
    model = StationFile
    # fields = "__all__"
    fields = ('name', 'file')
    success_message = "%(name)s was created successfully"
    layout = Layout(
        Fieldset('Add file to station',
                 Row('name'),
                 Row('file')
                 )
    )

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        station = Station.objects.get(pk=self.kwargs.get(
            'pk'))  # the self.kwargs is different from **kwargs, and gives access to the named url parameters
        context['station'] = station
        return context

    def form_valid(self, form):
        f = form.save(commit=False)
        station = Station.objects.get(pk=self.kwargs.get('pk'))
        f.station = station
        f.save()
        return super(StationFileCreate, self).form_valid(form)

    def get_success_url(self):
        return reverse('stationfiles-list', kwargs={'pk': self.kwargs.get('pk')})


class StationFileDelete(LoginRequiredMixin, DeleteView):
    model = StationFile
    success_message = "%(name)s was deleted successfully"

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        station = Station.objects.get(pk=self.kwargs.get(
            'pk_station'))  # the self.kwargs is different from **kwargs, and gives access to the named url parameters
        context['station'] = station
        return context

    def get_success_url(self):
        return reverse('stationfiles-list', kwargs={'pk': self.kwargs.get('pk_station')})


class StationVariableListView(LoginRequiredMixin, ListView):
    model = StationVariable

    def get_queryset(self):
        queryset = StationVariable.objects.filter(station__id=self.kwargs.get('pk'))
        return queryset

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        station = Station.objects.get(pk=self.kwargs.get(
            'pk'))  # the self.kwargs is different from **kwargs, and gives access to the named url parameters
        context['station'] = station
        return context


class StationVariableCreateView(LoginRequiredMixin, SuccessMessageMixin, CreateView):
    model = StationVariable
    fields = ('variable',)
    success_message = "%(variable)s was created successfully"
    layout = Layout(
        Fieldset('Add variable to station',
                 Row('variable')
                 )
    )

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        station = Station.objects.get(pk=self.kwargs.get(
            'pk'))  # the self.kwargs is different from **kwargs, and gives access to the named url parameters
        context['station'] = station
        return context

    def form_valid(self, form):
        f = form.save(commit=False)
        station = Station.objects.get(pk=self.kwargs.get('pk'))
        f.station = station
        f.save()
        return super(StationVariableCreateView, self).form_valid(form)

    def get_success_url(self):
        return reverse('stationvariable-list', kwargs={'pk': self.kwargs.get('pk')})


class StationVariableDeleteView(LoginRequiredMixin, DeleteView):
    model = StationVariable
    success_message = "%(action)s was deleted successfully"

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        station = Station.objects.get(pk=self.kwargs.get(
            'pk_station'))  # the self.kwargs is different from **kwargs, and gives access to the named url parameters
        context['station'] = station
        return context

    def get_success_url(self):
        return reverse('stationvariable-list', kwargs={'pk': self.kwargs.get('pk_station')})


def station_report_data(request):
    station = request.GET.get('station', None)
    initial_datetime = request.GET.get('initial_datetime', None)
    final_datetime = request.GET.get('final_datetime', None)
    source = request.GET.get('source', None)

    if station and initial_datetime and final_datetime and source:
        if int(source) == 0:  # Raw data
            dataset = get_raw_data('station', station, None, initial_datetime, final_datetime, 'raw_data')
        elif int(source) == 1:  # Hourly data
            dataset = get_raw_data('station', station, None, initial_datetime, final_datetime, 'hourly_summary')
        elif int(source) == 2:  # Daily data
            dataset = get_raw_data('station', station, None, initial_datetime, final_datetime, 'daily_summary')
        elif int(source) == 3:  # Monthly data
            dataset = get_raw_data('station', station, None, initial_datetime, final_datetime, 'monthly_summary')
        elif int(source) == 4:  # Yearly data
            dataset = get_raw_data('station', station, None, initial_datetime, final_datetime, 'yearly_summary')
        else:
            return JsonResponse({}, status=status.HTTP_404_NOT_FOUND)

        charts = {

        }

        for element_name, element_data in dataset['results'].items():

            chart = {
                'chart': {
                    'type': 'pie',
                    'zoomType': 'xy'
                },
                'title': {'text': element_name},
                'xAxis': {
                    'type': 'datetime',
                    'dateTimeLabelFormats': {
                        'month': '%e. %b',
                        'year': '%b'
                    },
                    'title': {
                        'text': 'Date'
                    }
                },
                'yAxis': [],
                'exporting': {
                    'showTable': True
                },
                'series': []
            }

            opposite = False
            y_axis_unit_dict = {}
            for variable_name, variable_data in element_data.items():

                current_unit = variable_data['unit']
                if current_unit not in y_axis_unit_dict.keys():
                    chart['yAxis'].append({
                        'labels': {
                            'format': '{value} ' + variable_data['unit'],
                        },
                        'title': {
                            'text': None
                        },
                        'opposite': opposite
                    })
                    y_axis_unit_dict[current_unit] = len(chart['yAxis']) - 1
                    opposite = not opposite

                current_y_axis_index = y_axis_unit_dict[current_unit]
                data = []
                for record in variable_data['data']:
                    if int(source) == 0:
                        data.append({
                            'x': record['date'],
                            'y': record['value'],
                            'quality_flag': record['quality_flag'],
                            'flag_color': record['flag_color']
                        })
                    elif int(source) == 3:
                        data.append({
                            'x': record['date'],
                            'y': record['value']
                        })

                        chart['xAxis'] = {
                            'type': 'datetime',
                            'labels': {
                                'format': '{value:%Y-%b}',
                            },
                            'title': {
                                'text': 'Y'
                            }
                        }
                    elif int(source) == 4:
                        data.append({
                            'x': record['date'],
                            'y': record['value']
                        })

                        chart['xAxis'] = {
                            'type': 'datetime',
                            'labels': {
                                'format': '{value:%Y-%b}',
                            },
                            'title': {
                                'text': 'Reference'
                            }
                        }
                    else:
                        data.append({
                            'x': record['date'],
                            'y': record['value']
                        })

                chart['series'].append({
                    'name': variable_name,
                    'color': variable_data['color'],
                    'type': variable_data['default_representation'],
                    'unit': variable_data['unit'],
                    'data': data,
                    'yAxis': current_y_axis_index
                })
                chart['chart']['type'] = variable_data['default_representation'],

            charts[slugify(element_name)] = chart

        return JsonResponse(charts)
    else:
        return JsonResponse({}, status=status.HTTP_400_BAD_REQUEST)


def variable_report_data(request):
    variable_ids_list = request.GET.get('variable_ids', None)
    initial_datetime = request.GET.get('initial_datetime', None)
    final_datetime = request.GET.get('final_datetime', None)
    source = request.GET.get('source', None)
    station_id_list = request.GET.get('station_ids', None)

    if variable_ids_list and initial_datetime and final_datetime and source and station_id_list:
        variable_ids_list = tuple(json.loads(variable_ids_list))
        station_id_list = tuple(json.loads(station_id_list))

        if int(source) == 0:  # Raw data
            dataset = get_station_raw_data('variable', variable_ids_list, None, initial_datetime, final_datetime,
                                           station_id_list, 'raw_data')
        elif int(source) == 1:  # Hourly data
            dataset = get_station_raw_data('variable', variable_ids_list, None, initial_datetime, final_datetime,
                                           station_id_list, 'hourly_summary')
        elif int(source) == 2:  # Daily data
            dataset = get_station_raw_data('variable', variable_ids_list, None, initial_datetime, final_datetime,
                                           station_id_list, 'daily_summary')
        elif int(source) == 3:  # Monthly data
            dataset = get_station_raw_data('variable', variable_ids_list, None, initial_datetime, final_datetime,
                                           station_id_list, 'monthly_summary')
        elif int(source) == 4:  # Yearly data
            dataset = get_station_raw_data('variable', variable_ids_list, None, initial_datetime, final_datetime,
                                           station_id_list, 'yearly_summary')
        else:
            return JsonResponse({}, status=status.HTTP_404_NOT_FOUND)

        charts = {

        }

        for element_name, element_data in dataset['results'].items():

            chart = {
                'chart': {
                    'type': 'pie',
                    'zoomType': 'xy'
                },
                'title': {'text': element_name},
                'xAxis': {
                    'type': 'datetime',
                    'dateTimeLabelFormats': {
                        'month': '%e. %b',
                        'year': '%b'
                    },
                    'title': {
                        'text': 'Date'
                    }
                },
                'yAxis': [],
                'exporting': {
                    'showTable': True
                },
                'series': []
            }

            opposite = False
            y_axis_unit_dict = {}
            for variable_name, variable_data in element_data.items():

                current_unit = variable_data['unit']
                if current_unit not in y_axis_unit_dict.keys():
                    chart['yAxis'].append({
                        'labels': {
                            'format': '{value} ' + variable_data['unit'],
                        },
                        'title': {
                            'text': None
                        },
                        'opposite': opposite
                    })
                    y_axis_unit_dict[current_unit] = len(chart['yAxis']) - 1
                    opposite = not opposite

                current_y_axis_index = y_axis_unit_dict[current_unit]
                data = []
                for record in variable_data['data']:
                    if int(source) == 0:
                        data.append({
                            'x': record['date'],
                            'y': record['value'],
                            'quality_flag': record['quality_flag'],
                            'flag_color': record['flag_color']
                        })
                    elif int(source) == 3:
                        data.append({
                            'x': record['date'],
                            'y': record['value']
                        })

                        chart['xAxis'] = {
                            'type': 'datetime',
                            'labels': {
                                'format': '{value:%Y-%b}',
                            },
                            'title': {
                                'text': 'Y'
                            }
                        }
                    elif int(source) == 4:
                        data.append({
                            'x': record['date'],
                            'y': record['value']
                        })

                        chart['xAxis'] = {
                            'type': 'datetime',
                            'labels': {
                                'format': '{value:%Y-%b}',
                            },
                            'title': {
                                'text': 'Reference'
                            }
                        }
                    else:
                        data.append({
                            'x': record['date'],
                            'y': record['value']
                        })

                chart['series'].append({
                    'name': variable_name,
                    'color': "#" + ''.join([random.choice('0123456789ABCDEF') for j in range(6)]),
                    'type': variable_data['default_representation'],
                    'unit': variable_data['unit'],
                    'data': data,
                    'yAxis': current_y_axis_index
                })
                chart['chart']['type'] = variable_data['default_representation'],

            charts[slugify(element_name)] = chart

        return JsonResponse(charts)
    else:
        return JsonResponse({}, status=status.HTTP_400_BAD_REQUEST)


class StationReportView(LoginRequiredMixin, TemplateView):
    template_name = "wx/products/station_report.html"

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)
        context['station_id'] = request.GET.get('station_id', 'null')

        station_list = Station.objects.all()
        context['station_list'] = station_list

        # interval_list = Interval.objects.filter(seconds__lte=3600).order_by('seconds')
        # context['interval_list'] = interval_list

        quality_flag_query = QualityFlag.objects.all()
        quality_flag_colors = {}
        for quality_flag in quality_flag_query:
            quality_flag_colors[quality_flag.name.replace(' ', '_')] = quality_flag.color
        context['quality_flag_colors'] = quality_flag_colors

        selected_station = station_list.first()
        if selected_station is not None:
            selected_station_id = selected_station.id
            station_variable_list = StationVariable.objects.filter(station__id=selected_station_id)
        else:
            station_variable_list = []

        context['station_variable_list'] = station_variable_list

        return self.render_to_response(context)


class VariableReportView(LoginRequiredMixin, TemplateView):
    template_name = "wx/products/variable_report.html"

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)

        quality_flag_query = QualityFlag.objects.all()
        quality_flag_colors = {}
        for quality_flag in quality_flag_query:
            quality_flag_colors[quality_flag.name.replace(' ', '_')] = quality_flag.color

        context['quality_flag_colors'] = quality_flag_colors
        context['variable_list'] = Variable.objects.all()
        context['station_list'] = Station.objects.all()

        return self.render_to_response(context)


class ProductReportView(LoginRequiredMixin, TemplateView):
    template_name = "wx/products/report.html"


class ProductCompareView(LoginRequiredMixin, TemplateView):
    template_name = 'wx/products/compare.html'

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)
        context['station_list'] = Station.objects.select_related('profile').all()
        context['variable_list'] = Variable.objects.select_related('unit').all()

        context['station_profile_list'] = StationProfile.objects.all()
        context['station_watershed_list'] = Watershed.objects.all()
        context['station_district_list'] = AdministrativeRegion.objects.all()

        return self.render_to_response(context)


class QualityControlView(LoginRequiredMixin, TemplateView):
    template_name = 'wx/quality_control/validation.html'

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)
        context['station_list'] = Station.objects.select_related('profile').all()

        context['station_profile_list'] = StationProfile.objects.all()
        context['station_watershed_list'] = Watershed.objects.all()
        context['station_district_list'] = AdministrativeRegion.objects.all()

        return self.render_to_response(context)


@csrf_exempt
def get_yearly_average(request):
    begin_date = request.GET.get('begin_date', None)
    end_date = request.GET.get('end_date', None)
    station_id = request.GET.get('station_id', None)
    variable_id = request.GET.get('variable_id', None)

    sql_string = """
        select avg(val.measured) as average, extract ('year' from month)::varchar as year, extract ('month' from month)::varchar as month, round(avg(val.measured)::decimal, 2)
        from generate_series(date_trunc('year', date %s),date_trunc('year', date %s) + interval '1 year' - interval '1 day', interval '1 month')  month
        left outer join raw_data as val on date_trunc('month', val.datetime) = date_trunc('month', month) and val.station_id = %s and val.variable_id = %s
        group by month
        order by month
    """
    where_parameters = [begin_date, end_date, station_id, variable_id]

    with connection.cursor() as cursor:
        cursor.execute(sql_string, where_parameters)
        rows = cursor.fetchall()

        years = {}
        for row in rows:
            if row[1] not in years.keys():
                years[row[1]] = {}

            if row[2] not in years[row[1]].keys():
                years[row[1]][row[2]] = row[3]

            years[row[1]][row[2]] = row[3]

        if not years:
            return JsonResponse({'message': 'No data found.'}, status=status.HTTP_400_BAD_REQUEST)

        return JsonResponse({'next': None, 'results': years}, safe=False, status=status.HTTP_200_OK)

    return JsonResponse({'message': 'Missing parameters.'}, status=status.HTTP_400_BAD_REQUEST)


class YearlyAverageReport(LoginRequiredMixin, TemplateView):
    template_name = 'wx/reports/yearly_average.html'


class StationVariableStationViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = StationVariable.objects.values('station__id', 'station__name', 'station__code').distinct('station__id')
    serializer_class = serializers.ReducedStationSerializer

    def get_queryset(self):
        queryset = StationVariable.objects.values('station__id', 'station__name', 'station__code').distinct(
            'station__id')

        variable_id = self.request.query_params.get('variable_id', None)

        if variable_id is not None:
            queryset = queryset.filter(variable__id=variable_id)

        return queryset

def last24_summary_list(request):
    search_type = request.GET.get('search_type', None)
    search_value = request.GET.get('search_value', None)

    response = {
        'results': [],
        'messages': [],
    }

    if search_type is not None and search_type == 'variable':
        query = """
            SELECT last24h.datetime,
                   var.name,
                   var.symbol,
                   var.sampling_operation_id,
                   unit.name,
                   unit.symbol,
                   last24h.min_value,
                   last24h.max_value,
                   last24h.avg_value,
                   last24h.sum_value,
                   last24h.latest_value,
                   last24h.station_id,
                   last24h.num_records
            FROM last24h_summary last24h
            JOIN wx_variable var ON last24h.variable_id=var.id
            JOIN wx_unit unit ON var.unit_id=unit.id
            WHERE last24h.variable_id=%s
        """

    with connection.cursor() as cursor:

        cursor.execute(query, [search_value])
        rows = cursor.fetchall()

        for row in rows:

            value = None

            if row[3] == 1:
                value = row[10]

            elif row[3] == 2:
                value = row[8]

            elif row[3] == 3:
                value = row[6]

            elif row[3] == 4:
                value = row[7]

            elif row[3] == 6:
                value = row[9]

            if value is None:
                print('variable {} does not have supported sampling operation {}'.format(row[1], row[3]))

            obj = {
                'station': row[11],
                'value': value,
                'min': round(row[6], 2),
                'max': round(row[7], 2),
                'avg': round(row[8], 2),
                'sum': round(row[9], 2),
                'count': row[12],
                'variable': {
                    'name': row[1],
                    'symbol': row[2],
                    'unit_name': row[4],
                    'unit_symbol': row[5]
                }
            }
            response['results'].append(obj)

        if response['results']:
            return JsonResponse(response, status=status.HTTP_200_OK)

    return JsonResponse(data={"message": "No data found."}, status=status.HTTP_404_NOT_FOUND)


def query_stationsmonintoring_chart(station_id, variable_id, data_type, datetime_picked):
    station = Station.objects.get(id=station_id)
    variable = Variable.objects.get(id=variable_id)

    date_start = str((datetime_picked - datetime.timedelta(days=6)).date())
    date_end = str(datetime_picked.date())

    if data_type=='Communication':
        query = """
            WITH
                date_range AS (
                    SELECT GENERATE_SERIES(%s::DATE - '6 day'::INTERVAL, %s::DATE, '1 day')::DATE AS date
                ),
                hs AS (
                    SELECT
                        datetime::date AS date,
                        COUNT(DISTINCT EXTRACT(hour FROM datetime)) AS amount
                    FROM
                        hourly_summary
                    WHERE
                        datetime >= %s::DATE - '7 day'::INTERVAL AND datetime < %s::DATE + '1 day'::INTERVAL
                        AND station_id = %s
                        AND variable_id = %s
                    GROUP BY 1
                )
            SELECT
                date_range.date,
                COALESCE(hs.amount, 0) AS amount,
                COALESCE((
                    SELECT color FROM wx_qualityflag
                    WHERE 
                        CASE 
                            WHEN COALESCE(hs.amount, 0) >= 20 THEN name = 'Good'
                            WHEN COALESCE(hs.amount, 0) >= 8 AND COALESCE(hs.amount, 0) <= 19 THEN name = 'Suspicious'
                            WHEN COALESCE(hs.amount, 0) >= 1 AND COALESCE(hs.amount, 0) <= 7 THEN name = 'Bad'
                            ELSE name = 'Not checked'
                        END
                ), '') AS color
            FROM
                date_range
                LEFT JOIN hs ON date_range.date = hs.date
            ORDER BY date_range.date;
        """

        with connection.cursor() as cursor:
            cursor.execute(query, (datetime_picked, datetime_picked, datetime_picked, datetime_picked, station_id, variable_id,))
            results = cursor.fetchall()

        chart_options = {
            'chart': {
                'type': 'column'
            },
            'title': {
                'text': " ".join(['Delay Data Track -',date_start,'to',date_end]) 
            },
            'subtitle': {
                'text': " ".join([station.name, station.code, '-', variable.name])
            },  
            'xAxis': {
                'categories': [r[0] for r in results]
            },
            'yAxis': {
                'title': None,
                'categories': [str(i)+'h' for i in range(25)],      
                'tickInterval': 2,
                'min': 0,
                'max': 24,
            },
            'series': [
                {
                    'name': 'Max comunication',
                    'data': [{'y': r[1], 'color': r[2]} for r in results],
                    'showInLegend': False
                }
            ],
            'plotOptions': {
                'column': {
                    'minPointLength': 10,
                    'pointPadding': 0.01,
                    'groupPadding': 0.05
                }
            }            
        }

    elif data_type=='Quality Control':
        flags = {
          'good': QualityFlag.objects.get(name='Good').color,
          'suspicious': QualityFlag.objects.get(name='Suspicious').color,
          'bad': QualityFlag.objects.get(name='Bad').color,
          'not_checked': QualityFlag.objects.get(name='Not checked').color,
        }        

        query = """
            WITH
              date_range AS (
                SELECT GENERATE_SERIES(%s::DATE - '6 day'::INTERVAL, %s::DATE, '1 day')::DATE AS date
              ),
              hs AS(              
                SELECT 
                    rd.datetime::DATE AS date
                    ,EXTRACT(hour FROM rd.datetime) AS hour
                    ,CASE
                      WHEN COUNT(CASE WHEN name='Bad' THEN 1 END) > 0 THEN('Bad')
                      WHEN COUNT(CASE WHEN name='Suspicious' THEN 1 END) > 0 THEN('Suspicious')
                      WHEN COUNT(CASE WHEN name='Good' THEN 1 END) > 0 THEN('Good')
                      ELSE ('Not checked')
                    END AS quality_flag
                FROM raw_data AS rd
                    LEFT JOIN wx_qualityflag qf ON rd.quality_flag = qf.id
                WHERE 
                    datetime >= %s::DATE - '7 day'::INTERVAL AND datetime < %s::DATE + '1 day'::INTERVAL
                    AND rd.station_id = %s
                    AND rd.variable_id = %s
                GROUP BY 1,2
                ORDER BY 1,2
              )
            SELECT
                date_range.date
                ,COUNT(CASE WHEN hs.quality_flag='Good' THEN 1 END) AS good
                ,COUNT(CASE WHEN hs.quality_flag='Suspicious' THEN 1 END) AS suspicious
                ,COUNT(CASE WHEN hs.quality_flag='Bad' THEN 1 END) AS bad
                ,COUNT(CASE WHEN hs.quality_flag='Not checked' THEN 1 END) AS not_checked
            FROM date_range
                LEFT JOIN hs ON date_range.date = hs.date
            GROUP BY 1
            ORDER BY 1;
        """

        with connection.cursor() as cursor:
            cursor.execute(query, (datetime_picked, datetime_picked, datetime_picked, datetime_picked, station_id, variable_id,))
            results = cursor.fetchall()

        series = [] 
        for i, flag in enumerate(flags):
            data = [r[i+1] for r in results]
            series.append({'name': flag.capitalize(), 'data': data, 'color': flags[flag]})

        chart_options = {
            'chart': {
                'type': 'column'
            },
            'title': {
                'text': " ".join(['Amount of Flags - ',date_start,'to',date_end]) 
            },
            'subtitle': {
                'text': " ".join([station.name, station.code, '-', variable.name])
            },            
            'xAxis': {
                'categories': [r[0] for r in results]
            },
            'yAxis': {
                'title': None,
                'categories': [str(i)+'h' for i in range(25)],      
                'tickInterval': 2,
                'min': 0,
                'max': 24,
            },
            'series': series,
            'plotOptions': {
                'column': {
                    'minPointLength': 10, 
                    'pointPadding': 0.01,
                    'groupPadding': 0.05
                }
            }            
        }            

    return chart_options


@require_http_methods(["GET"])    
def get_stationsmonitoring_chart_data(request, station_id, variable_id):
    time_type = request.GET.get('time_type', 'Last 24h')
    data_type = request.GET.get('data_type', 'Communication')
    date_picked = request.GET.get('date_picked', None)

    if time_type=='Last 24h':
        datetime_picked = datetime.datetime.now()
    else:
        datetime_picked = datetime.datetime.strptime(date_picked, '%Y-%m-%d')    

    # Fix a date to test
    # datetime_picked = datetime.datetime.strptime('2023-01-01', '%Y-%m-%d')

    chart_data = query_stationsmonintoring_chart(station_id, variable_id, data_type, datetime_picked)

    response = {
        "chartOptions": chart_data
    }

    return JsonResponse(response, status=status.HTTP_200_OK)


def get_station_lastupdate(station_id):
    stationvariables = StationVariable.objects.filter(station_id=station_id)
    
    last_data_datetimes = [sv.last_data_datetime for sv in stationvariables if sv.last_data_datetime is not None]

    if last_data_datetimes:
        lastupdate = max(last_data_datetimes)
        lastupdate = lastupdate.strftime("%Y-%m-%d %H:%M")
    else:
        lastupdate = None

    return lastupdate


def query_stationsmonitoring_station(data_type, time_type, date_picked, station_id):
    if time_type=='Last 24h':
        datetime_picked = datetime.datetime.now()
    else:
        datetime_picked = datetime.datetime.strptime(date_picked, '%Y-%m-%d')


    station_data = []

    if data_type=='Communication':
        query = """
            WITH hs AS (
                SELECT
                    station_id,
                    variable_id,
                    COUNT(DISTINCT EXTRACT(hour FROM datetime)) AS number_hours
                FROM
                    hourly_summary
                WHERE
                    datetime <= %s AND datetime >= %s - '24 hour'::INTERVAL AND station_id = %s
                GROUP BY 1, 2
            )
            SELECT
                v.id,
                v.name,
                hs.number_hours,
                ls.latest_value,
                u.symbol,                    
                CASE
                    WHEN hs.number_hours >= 20 THEN (
                        SELECT color FROM wx_qualityflag WHERE name = 'Good'
                    )
                    WHEN hs.number_hours >= 8 AND hs.number_hours <= 19 THEN(
                        SELECT color FROM wx_qualityflag WHERE name = 'Suspicious'
                    )
                    WHEN hs.number_hours >= 1 AND hs.number_hours <= 7 THEN(
                        SELECT color FROM wx_qualityflag WHERE name = 'Bad'
                    )
                    ELSE (
                        SELECT color FROM wx_qualityflag WHERE name = 'Not checked'
                    )
                END AS color                     
            FROM
                wx_stationvariable sv
                LEFT JOIN hs ON sv.station_id = hs.station_id AND sv.variable_id = hs.variable_id
                LEFT JOIN last24h_summary ls ON sv.station_id = ls.station_id AND sv.variable_id = ls.variable_id
                LEFT JOIN wx_variable v ON sv.variable_id = v.id
                LEFT JOIN wx_unit u ON v.unit_id = u.id
            WHERE
                sv.station_id = %s
            ORDER BY 1;
        """

        with connection.cursor() as cursor:
            cursor.execute(query, (datetime_picked, datetime_picked, station_id, station_id))
            results = cursor.fetchall()

        station_data = [{'id': r[0], 
                         'name': r[1], 
                         'amount': r[2] if r[2] is not None else 0, 
                         'latestvalue': " ".join([str(r[3]), r[4]]) if r[3] is not None else '---', 
                         'color': r[5]} for r in results]

    elif data_type=='Quality Control':
        query = """
            WITH h AS(
                SELECT 
                    rd.station_id
                    ,rd.variable_id
                    ,EXTRACT(hour FROM rd.datetime) AS hour
                    ,CASE
                      WHEN COUNT(CASE WHEN name='Bad' THEN 1 END) > 0 THEN('Bad')
                      WHEN COUNT(CASE WHEN name='Suspicious' THEN 1 END) > 0 THEN('Suspicious')
                      WHEN COUNT(CASE WHEN name='Good' THEN 1 END) > 0 THEN('Good')
                      ELSE ('Not checked')
                    END AS quality_flag
                FROM raw_data AS rd
                    LEFT JOIN wx_qualityflag qf ON rd.quality_flag = qf.id
                WHERE 
                    datetime <= %s
                    AND datetime >= %s - '24 hour'::INTERVAL
                    AND rd.station_id = %s
                GROUP BY 1,2,3
                ORDER BY 1,2,3
            )
            SELECT
                v.id
                ,v.name
                ,COUNT(CASE WHEN h.quality_flag='Good' THEN 1 END) AS good
                ,COUNT(CASE WHEN h.quality_flag='Suspicious' THEN 1 END) AS suspicious
                ,COUNT(CASE WHEN h.quality_flag='Bad' THEN 1 END) AS bad
                ,COUNT(CASE WHEN h.quality_flag='Not checked' THEN 1 END) AS not_checked
            FROM wx_stationvariable AS sv
                LEFT JOIN wx_variable AS v ON sv.variable_id = v.id
                LEFT JOIN h ON sv.station_id = h.station_id AND sv.variable_id = h.variable_id
            WHERE sv.station_id = %s
            GROUP BY 1,2
            ORDER BY 1,2
        """

        with connection.cursor() as cursor:
            cursor.execute(query, (datetime_picked, datetime_picked, station_id, station_id))
            results = cursor.fetchall()

        station_data = [{'id': r[0], 
                         'name': r[1], 
                         'good': r[2],
                         'suspicious': r[3],
                         'bad': r[4],
                         'not_checked': r[5]} for r in results]
    elif data_type=='Visits':
        query = """
            WITH ordered_reports AS (
                SELECT 
                    id
                    ,station_id
                    ,visit_type_id
                    ,visit_date
                    ,initial_time
                    ,end_time
                    ,responsible_technician_id
                    ,next_visit_date
                    ,ROW_NUMBER() OVER (PARTITION BY station_id ORDER BY visit_date DESC) AS rn
                FROM wx_maintenancereport
                WHERE status='A'AND station_id=%s
            )
            ,latest_report AS(
                SELECT 
                    *
                FROM ordered_reports
                WHERE rn=1    
            )
            SELECT 
                r.id
                ,p.name
                ,s.is_automatic
                ,r.visit_date
                ,v.name
                ,r.initial_time
                ,r.end_time
                ,t.name
                ,r.next_visit_date
            FROM latest_report r
            LEFT JOIN wx_station s ON r.station_id = s.id
            LEFT JOIN wx_stationprofile p ON p.id=s.profile_id
            LEFT JOIN wx_technician t ON r.responsible_technician_id = t.id
            LEFT JOIN wx_visittype v ON r.visit_type_id = v.id
        """

        with connection.cursor() as cursor:
            cursor.execute(query, (station_id,))
            results = cursor.fetchall()
        
        station_data = [{'Maintenance Report ID': r[0],
                         'Station Profile': r[1],
                         'Station Type': 'Automatic' if r[2] else 'Manual',
                         'Visit Date': r[3],
                         'Visit Type': r[4],
                         'Initial Time': r[5],
                         'End Time': r[6],
                         'Responsible Technician': r[7],
                         'Next Visit Date': r[8]} for r in results]
        
        if len(station_data)>0:
            station_data = station_data[0]
        else:
            station_data = {}
    elif data_type=='Equipment':
        query = """
            WITH ordered_reports AS (
                SELECT 
                    id
                    ,ROW_NUMBER() OVER (PARTITION BY station_id ORDER BY visit_date DESC) AS rn
                FROM wx_maintenancereport
                WHERE status='A'AND station_id=%s
            )
            ,latest_report AS(
                SELECT 
                    id
                FROM ordered_reports
                WHERE rn=1    
            )
            SELECT 
                e.model
                ,e.serial_number
                ,et.name
                ,se.classification
                ,q.color
            FROM latest_report r
            LEFT JOIN wx_maintenancereportequipment se ON se.maintenance_report_id=r.id
            LEFT JOIN wx_equipment e ON e.id = se.new_equipment_id
            LEFT JOIN wx_equipmenttype et ON et.id = se.equipment_type_id
            LEFT JOIN
                    wx_qualityflag q ON 
                    CASE
                        WHEN se.classification='N' THEN q.symbol = 'B'
                        WHEN se.classification='P' THEN q.symbol = 'S'
                        WHEN se.classification='F' THEN q.symbol = 'G'
                        ELSE q.symbol = '-'
                    END
            ORDER BY se.equipment_type_id, se.equipment_order
        """

        with connection.cursor() as cursor:
            cursor.execute(query, (station_id,))
            results = cursor.fetchall()

        classification_dict = {
            'F':  'Fully Functional',
            'P':  'Partially Functional',
            'N':  'Not Functional'
        }
        
        station_data = [{'model': r[0],
                         'serial_number': r[1],
                         'equipment_type': r[2],
                         'classification': classification_dict[r[3]],
                         'color': r[4]} for r in results]        
    return station_data


@require_http_methods(["GET"])
def get_stationsmonitoring_station_data(request, id):
    data_type = request.GET.get('data_type', 'Communication')
    time_type = request.GET.get('time_type', 'Last 24h')
    date_picked = request.GET.get('date_picked', None)

    response = {
        'lastupdate': get_station_lastupdate(id),
        'station_data': query_stationsmonitoring_station(data_type, time_type, date_picked, id),
    }

    return JsonResponse(response, status=status.HTTP_200_OK)


def query_stationsmonitoring_map(data_type, time_type, date_picked):
    if time_type=='Last 24h':
        datetime_picked = datetime.datetime.now()
    else:
        datetime_picked = datetime.datetime.strptime(date_picked, '%Y-%m-%d')

    results = []

    if time_type=='Last 24h':
        if data_type=='Communication':
            query = """
                WITH hs AS (
                    SELECT
                        station_id
                        ,variable_id
                        ,COUNT(DISTINCT EXTRACT(hour FROM datetime)) AS number_hours
                    FROM
                        hourly_summary
                    WHERE
                        datetime <= %s AND datetime >= %s - '24 hour'::INTERVAL
                    GROUP BY 1, 2
                )
                SELECT
                    s.id
                    ,s.name
                    ,s.code
                    ,s.latitude
                    ,s.longitude
                    ,CASE
                        WHEN MAX(number_hours) >= 20 THEN (
                            SELECT color FROM wx_qualityflag WHERE name = 'Good'
                        )
                        WHEN MAX(number_hours) >= 8 AND MAX(number_hours) <= 19 THEN(
                            SELECT color FROM wx_qualityflag WHERE name = 'Suspicious'
                        )
                        WHEN MAX(number_hours) >= 1 AND MAX(number_hours) <= 7 THEN(
                            SELECT color FROM wx_qualityflag WHERE name = 'Bad'
                        )
                        ELSE (
                            SELECT color FROM wx_qualityflag WHERE name = 'Not checked'
                        )
                    END AS color    
                FROM wx_station AS s
                    LEFT JOIN wx_stationvariable AS sv ON s.id = sv.station_id
                    LEFT JOIN hs ON sv.station_id = hs.station_id AND sv.variable_id = hs.variable_id
                WHERE s.is_active
                GROUP BY 1, 2, 3, 4, 5;
            """
        elif data_type=='Quality Control':
            query = """
                WITH qf AS (
                  SELECT
                    station_id
                    ,CASE
                      WHEN COUNT(CASE WHEN name='Bad' THEN 1 END) > 0 THEN(
                          SELECT color FROM wx_qualityflag WHERE name = 'Bad'
                      )
                      WHEN COUNT(CASE WHEN name='Suspicious' THEN 1 END) > 0 THEN(
                          SELECT color FROM wx_qualityflag WHERE name = 'Suspicious'
                      )   
                      WHEN COUNT(CASE WHEN name='Good' THEN 1 END) > 0 THEN(
                          SELECT color FROM wx_qualityflag WHERE name = 'Good'
                      )
                      ELSE (
                          SELECT color FROM wx_qualityflag WHERE name = 'Not checked'
                      )
                    END AS color
                  FROM
                    raw_data AS rd
                    LEFT JOIN wx_qualityflag AS qf ON rd.quality_flag = qf.id
                  WHERE
                        datetime <= %s AND datetime >= %s - '24 hour'::INTERVAL                
                  GROUP BY 1
                )
                SELECT
                  s.id
                  ,s.name
                  ,s.code
                  ,s.latitude
                  ,s.longitude
                  ,COALESCE(qf.color, (SELECT color FROM wx_qualityflag WHERE name = 'Not checked')) AS color
                FROM wx_station AS s
                LEFT JOIN qf ON s.id = qf.station_id
                WHERE s.is_active
            """
        elif data_type=='Visits':
            query = """
                WITH ordered_reports AS (
                    SELECT 
                        id
                        ,station_id
                        ,visit_date
                        ,next_visit_date
                        ,ROW_NUMBER() OVER (PARTITION BY station_id ORDER BY visit_date DESC) AS rn
                    FROM wx_maintenancereport
                    WHERE status='A'
                )
                ,latest_reports AS(
                    SELECT 
                        id
                        ,station_id
                        ,visit_date
                        ,next_visit_date
                        ,rn
                    FROM ordered_reports
                    WHERE rn=1    
                )
                SELECT 
                    s.id
                    ,s.name
                    ,s.code
                    ,s.latitude
                    ,s.longitude                    
                    ,q.color AS color
                FROM wx_station s
                LEFT JOIN latest_reports l ON l.station_id = s.id
                LEFT JOIN wx_qualityflag q ON
                    CASE
                        WHEN l.next_visit_date IS NULL THEN q.symbol = '-'
                        WHEN l.next_visit_date > NOW() THEN q.symbol = 'G'
                        WHEN l.next_visit_date >= NOW() - INTERVAL '1 month' AND l.next_visit_date <= NOW() THEN q.symbol = 'S'
                        WHEN l.next_visit_date < NOW() - INTERVAL '1 month' THEN q.symbol = 'B'
                    END
                WHERE s.is_active
            """
        elif data_type == 'Equipment':
            query = """
                WITH ordered_reports AS (
                    SELECT 
                        id
                        ,station_id
                        ,visit_date
                        ,next_visit_date
                        ,ROW_NUMBER() OVER (PARTITION BY station_id ORDER BY visit_date DESC) AS rn
                    FROM wx_maintenancereport
                    WHERE status='A'
                )
                ,latest_reports AS(
                    SELECT 
                        id
                        ,station_id
                        ,visit_date
                        ,next_visit_date
                        ,rn
                    FROM ordered_reports
                    WHERE rn=1    
                )
                ,station_equipment AS (
                    SELECT 
                        r.station_id
                        ,COUNT(*) AS count_eq
                        ,SUM(CASE WHEN re.classification = 'F' THEN 1 ELSE 0 END) AS count_f
                        ,SUM(CASE WHEN re.classification = 'P' THEN 1 ELSE 0 END) AS count_p
                        ,SUM(CASE WHEN re.classification = 'N' THEN 1 ELSE 0 END) AS count_n
                    FROM latest_reports r
                    LEFT JOIN wx_maintenancereportequipment re 
                        ON  re.maintenance_report_id = r.id
                    GROUP BY r.station_id
                )
                SELECT
                    s.id,
                    s.name,
                    s.code,
                    s.latitude,
                    s.longitude,
                    q.color AS color
                FROM
                    wx_station s
                LEFT JOIN
                    station_equipment se ON se.station_id = s.id
                LEFT JOIN
                    wx_qualityflag q ON 
                    CASE
                        WHEN se.count_eq IS NULL THEN q.symbol = '-'
                        WHEN se.count_n > 0 THEN q.symbol = 'B'
                        WHEN se.count_p > 0 THEN q.symbol = 'S'
                        ELSE q.symbol = 'G'
                    END
                WHERE
                    s.is_active
            """            
            

        if data_type in ['Communication', 'Quality Control']:
            with connection.cursor() as cursor:
                cursor.execute(query, (datetime_picked, datetime_picked, ))
                results = cursor.fetchall()
        elif data_type in ['Visits', 'Equipment']:
            with connection.cursor() as cursor:
                cursor.execute(query)
                results = cursor.fetchall()
    else:
        if data_type=='Communication':
            query = """
                WITH hs AS (
                    SELECT
                        station_id
                        ,variable_id
                        ,COUNT(DISTINCT EXTRACT(hour FROM datetime)) AS number_hours
                    FROM
                        hourly_summary
                    WHERE
                        datetime <= %s AND datetime >= %s - '24 hour'::INTERVAL
                    GROUP BY 1, 2
                )
                SELECT
                    s.id
                    ,s.name
                    ,s.code
                    ,s.latitude
                    ,s.longitude
                    ,CASE
                        WHEN MAX(number_hours) >= 20 THEN (
                            SELECT color FROM wx_qualityflag WHERE name = 'Good'
                        )
                        WHEN MAX(number_hours) >= 8 AND MAX(number_hours) <= 19 THEN(
                            SELECT color FROM wx_qualityflag WHERE name = 'Suspicious'
                        )
                        WHEN MAX(number_hours) >= 1 AND MAX(number_hours) <= 7 THEN(
                            SELECT color FROM wx_qualityflag WHERE name = 'Bad'
                        )
                        ELSE (
                            SELECT color FROM wx_qualityflag WHERE name = 'Not checked'
                        )
                    END AS color    
                FROM wx_station AS s
                    LEFT JOIN wx_stationvariable AS sv ON s.id = sv.station_id
                    LEFT JOIN hs ON sv.station_id = hs.station_id AND sv.variable_id = hs.variable_id
                WHERE s.begin_date <= %s AND (s.end_date IS NULL OR s.end_date >= %s)
                GROUP BY 1, 2, 3, 4, 5;
            """
        elif data_type=='Quality Control':
            query = """
                WITH qf AS (
                  SELECT
                    station_id
                    ,CASE
                      WHEN COUNT(CASE WHEN name='Bad' THEN 1 END) > 0 THEN(
                          SELECT color FROM wx_qualityflag WHERE name = 'Bad'
                      )
                      WHEN COUNT(CASE WHEN name='Suspicious' THEN 1 END) > 0 THEN(
                          SELECT color FROM wx_qualityflag WHERE name = 'Suspicious'
                      )   
                      WHEN COUNT(CASE WHEN name='Good' THEN 1 END) > 0 THEN(
                          SELECT color FROM wx_qualityflag WHERE name = 'Good'
                      )
                      ELSE (
                          SELECT color FROM wx_qualityflag WHERE name = 'Not checked'
                      )
                    END AS color
                  FROM
                    raw_data AS rd
                    LEFT JOIN wx_qualityflag AS qf ON rd.quality_flag = qf.id
                  WHERE
                        datetime <= %s AND datetime >= %s - '24 hour'::INTERVAL                
                  GROUP BY 1
                )
                SELECT
                  s.id
                  ,s.name
                  ,s.code
                  ,s.latitude
                  ,s.longitude
                  ,COALESCE(qf.color, (SELECT color FROM wx_qualityflag WHERE name = 'Not checked')) AS color
                FROM wx_station AS s
                LEFT JOIN qf ON s.id = qf.station_id
                WHERE s.begin_date <= %s AND (s.end_date IS NULL OR s.end_date >= %s)
            """

        if data_type in ['Communication', 'Quality Control']:
            with connection.cursor() as cursor:
                cursor.execute(query, (datetime_picked, datetime_picked, datetime_picked, datetime_picked, ))
                results = cursor.fetchall()

    return results


@require_http_methods(["GET"])
def get_stationsmonitoring_map_data(request):
    time_type = request.GET.get('time_type', 'Last 24h')
    data_type = request.GET.get('data_type', 'Communication')
    date_picked = request.GET.get('date_picked', None)

    results = query_stationsmonitoring_map(data_type, time_type, date_picked)

    response = {
        'stations': [{'id': r[0],
                      'name': r[1],
                      'code': r[2],
                      'position': [r[3], r[4]],
                      'color': r[5]} for r in results ],
    }

    return JsonResponse(response, status=status.HTTP_200_OK)


def stationsmonitoring_form(request):
    template = loader.get_template('wx/stations/stations_monitoring.html')

    flags = {
      'good': QualityFlag.objects.get(name='Good').color,
      'suspicious': QualityFlag.objects.get(name='Suspicious').color,
      'bad': QualityFlag.objects.get(name='Bad').color,
      'not_checked': QualityFlag.objects.get(name='Not checked').color,
    }

    context = {'flags': flags}

    return HttpResponse(template.render(context, request))


class ComingSoonView(LoginRequiredMixin, TemplateView):
    template_name = "coming-soon.html"

def get_wave_data_analysis(request):
    template = loader.get_template('wx/products/wave_data.html')


    variable = Variable.objects.get(name="Sea Level") # Sea Level
    station_ids = HighFrequencyData.objects.filter(variable_id=variable.id).values('station_id').distinct()

    station_list = Station.objects.filter(id__in=station_ids)

    context = {'station_list': station_list}

    return HttpResponse(template.render(context, request))

def format_wave_data_var(variable_id, data):
    variable = Variable.objects.get(id=variable_id)
    measurement_variable = MeasurementVariable.objects.get(id=variable.measurement_variable_id)
    unit = Unit.objects.get(id=variable.unit_id)

    formated_data = []
    for entry in data:
        if type(entry) is not dict:
            entry = entry.__dict__

        formated_entry = {
            "station": entry['station_id'],
            "date": entry['datetime'].timestamp()*1000,
            "measurementvariable": measurement_variable.name,
            "value": entry['measured'],
            "quality_flag": "Not checked",
            "flag_color": "#FFFFFF",            
        }
        formated_data.append(formated_entry)

    final_data = {
        "color": variable.color,
        "default_representation": variable.default_representation,
        "data": formated_data,
        "unit": unit.symbol,
    }
    return final_data

def get_wave_components(data_slice, component_number):
    wave_list = fft_decompose(data_slice)    
    wave_list.sort(key=lambda W: abs(W.height), reverse=True)
    wave_components = wave_list[:component_number]
    return wave_components

def get_wave_component_ref_variables(i):
    SYSTEM_COMPONENT_NUMBER = 5 # Number of wave components in the system

    ref_number = i % SYSTEM_COMPONENT_NUMBER
    ref_number += 1

    amp_ref_name = 'Wave Component ' + str(ref_number) + ' Amplitude'
    amp_ref = Variable.objects.get(name=amp_ref_name)

    frq_ref_name = 'Wave Component ' + str(ref_number) + ' Frequency'
    frq_ref = Variable.objects.get(name=frq_ref_name)

    pha_ref_name = 'Wave Component ' + str(ref_number) + ' Phase'
    pha_ref = Variable.objects.get(name=pha_ref_name)

    return amp_ref, frq_ref, pha_ref

def get_wave_component_name_and_symbol(i, component_type):
    if component_type=='Amplitude':
        name = 'Wave Component ' + str(i) + ' Amplitude'
        symbol = 'WV'+str(i)+'AMP'
    elif component_type=='Frequency':
        name = 'Wave Component ' + str(i) + ' Frequency'
        symbol = 'WV'+str(i)+'FRQ'
    elif component_type=='Phase':
        name = 'Wave Component ' + str(i) + ' Phase'
        symbol = 'WV'+str(i)+'PHA'
    else:
        name = 'Component Type Error'
        symbol = 'Component Type Error'

    return name, symbol

def create_aggregated_data(component_number):
    wv_amp_mv = MeasurementVariable.objects.get(name='Wave Amplitude')
    wv_frq_mv = MeasurementVariable.objects.get(name='Wave Frequency')
    wv_pha_mv = MeasurementVariable.objects.get(name='Wave Phase')
    sl_mv = MeasurementVariable.objects.get(name='Sea Level')

    sl_min = Variable.objects.get(name = 'Sea Level [MIN]')
    sl_max = Variable.objects.get(name = 'Sea Level [MAX]')
    sl_avg = Variable.objects.get(name = 'Sea Level [AVG]')
    sl_std = Variable.objects.get(name = 'Sea Level [STDV]')
    sl_swh = Variable.objects.get(name = 'Significant Wave Height')

    sl_variables = [sl_min, sl_max, sl_avg, sl_std, sl_swh]


    aggregated_data = {
        wv_amp_mv.name: {},
        wv_frq_mv.name: {},
        wv_pha_mv.name: {},
        sl_mv.name: {}
    }

    for sl_variable in sl_variables:
        aggregated_data[sl_mv.name][sl_variable.name] = {
            'ref_variable_id': sl_variable.id,         
            'symbol': sl_variable.symbol,
            'data': []    
        }    

    for i in range(component_number):
        amp_ref, frq_ref, pha_ref = get_wave_component_ref_variables(i)

        amp_name, amp_symbol = get_wave_component_name_and_symbol(i+1, 'Amplitude')
        frq_name, frq_symbol = get_wave_component_name_and_symbol(i+1, 'Frequency')
        pha_name, pha_symbol = get_wave_component_name_and_symbol(i+1, 'Phase')

        aggregated_data[wv_amp_mv.name][amp_name] = {
            'ref_variable_id': amp_ref.id,         
            'symbol': amp_symbol,
            'data': []            
        }
        aggregated_data[wv_frq_mv.name][frq_name] = {        
            'ref_variable_id': frq_ref.id,         
            'symbol': frq_symbol,
            'data': []
        }
        aggregated_data[wv_pha_mv.name][pha_name] = {
            'ref_variable_id': pha_ref.id,         
            'symbol': pha_symbol,
            'data': []            
        }

    return aggregated_data

def append_in_aggregated_data(aggregated_data, datetime, station_id, mv_name, var_name, value):
    entry = {
        'measured': value,
        'datetime': datetime,
        'station_id': station_id,
    }

    aggregated_data[mv_name][var_name]['data'].append(entry)

    return aggregated_data

def get_wave_aggregated_data(station_id, data, initial_datetime, range_interval, calc_interval, component_number):
    wv_amp_mv = MeasurementVariable.objects.get(name='Wave Amplitude')
    wv_frq_mv = MeasurementVariable.objects.get(name='Wave Frequency')
    wv_pha_mv = MeasurementVariable.objects.get(name='Wave Phase')
    sl_mv = MeasurementVariable.objects.get(name='Sea Level')

    sl_min = Variable.objects.get(name = 'Sea Level [MIN]')
    sl_max = Variable.objects.get(name = 'Sea Level [MAX]')
    sl_avg = Variable.objects.get(name = 'Sea Level [AVG]')
    sl_std = Variable.objects.get(name = 'Sea Level [STDV]')
    sl_swh = Variable.objects.get(name = 'Significant Wave Height')

    aggregated_data = create_aggregated_data(component_number)

    for i in range(math.floor(range_interval/calc_interval)):
        ini_datetime_slc = initial_datetime+datetime.timedelta(minutes=i*calc_interval)
        end_datetime_slc = initial_datetime+datetime.timedelta(minutes=(i+1)*calc_interval)

        data_slice = [entry.measured for entry in data if ini_datetime_slc < entry.datetime <= end_datetime_slc]

        if len(data_slice) > 0:
            aggregated_data = append_in_aggregated_data(aggregated_data, end_datetime_slc, station_id, sl_mv.name, sl_min.name, np.min(data_slice))
            aggregated_data = append_in_aggregated_data(aggregated_data, end_datetime_slc, station_id, sl_mv.name, sl_max.name, np.max(data_slice))
            aggregated_data = append_in_aggregated_data(aggregated_data, end_datetime_slc, station_id, sl_mv.name, sl_avg.name, np.mean(data_slice))
            aggregated_data = append_in_aggregated_data(aggregated_data, end_datetime_slc, station_id, sl_mv.name, sl_std.name, np.std(data_slice))
            aggregated_data = append_in_aggregated_data(aggregated_data, end_datetime_slc, station_id, sl_mv.name, sl_swh.name, 4*np.std(data_slice))

            wave_components = get_wave_components(data_slice, component_number)
            for j, wave_component in enumerate(wave_components):
                amp_name, amp_symbol = get_wave_component_name_and_symbol(j+1, 'Amplitude')
                frq_name, frq_symbol = get_wave_component_name_and_symbol(j+1, 'Frequency')
                pha_name, pha_symbol = get_wave_component_name_and_symbol(j+1, 'Phase')

                amp_value = wave_component.height
                frq_value = wave_component.frequency
                pha_value = math.degrees(wave_component.phase_rad) % 360

                aggregated_data = append_in_aggregated_data(aggregated_data, end_datetime_slc, station_id, wv_amp_mv.name, amp_name, amp_value)
                aggregated_data = append_in_aggregated_data(aggregated_data, end_datetime_slc, station_id, wv_frq_mv.name, frq_name, frq_value)
                aggregated_data = append_in_aggregated_data(aggregated_data, end_datetime_slc, station_id, wv_pha_mv.name, pha_name, pha_value)

    return aggregated_data

def add_wave_aggregated_data(dataset, aggregated_data):
    for mv_name in aggregated_data.keys():
        dataset['results'][mv_name] = {}
        for var_name in aggregated_data[mv_name].keys():
            variable_id = aggregated_data[mv_name][var_name]['ref_variable_id']
            variable_data = aggregated_data[mv_name][var_name]['data']
            variable_symbol = aggregated_data[mv_name][var_name]['symbol']

            dataset['results'][mv_name][variable_symbol] = format_wave_data_var(variable_id, variable_data)

    return dataset    

def create_wave_dataset(station_id, sea_data, initial_datetime, range_interval, calc_interval, component_number):
    sea_level = Variable.objects.get(name='Sea Level')
    sea_level_mv = MeasurementVariable.objects.get(name='Sea Level')

    dataset  = {
        "results": {
            sea_level_mv.name+' Raw': {
                sea_level.symbol: format_wave_data_var(sea_level.id, sea_data),
            }
        },
        "messages": [],
    }

    wave_component_data = get_wave_aggregated_data(station_id,
                                                  sea_data,
                                                  initial_datetime,
                                                  range_interval,
                                                  calc_interval,
                                                  component_number)

 
    dataset = add_wave_aggregated_data(dataset, wave_component_data)

    return dataset

def create_wave_chart(dataset):
    charts = {}

    for element_name, element_data in dataset['results'].items():

        chart = {
            'chart': {
                'type': 'pie',
                'zoomType': 'xy'
            },
            'title': {'text': element_name},
            'xAxis': {
                'type': 'datetime',
                'dateTimeLabelFormats': {
                    'month': '%e. %b',
                    'year': '%b'
                },
                'title': {
                    'text': 'Date'
                }
            },
            'yAxis': [],
            'exporting': {
                'showTable': True
            },
            'series': []
        }

        opposite = False
        y_axis_unit_dict = {}
        for variable_name, variable_data in element_data.items():
            current_unit = variable_data['unit']
            if current_unit not in y_axis_unit_dict.keys():
                chart['yAxis'].append({
                    'labels': {
                        'format': '{value} ' + variable_data['unit'],
                    },
                    'title': {
                        'text': None
                    },
                    'opposite': opposite
                })
                y_axis_unit_dict[current_unit] = len(chart['yAxis']) - 1
                opposite = not opposite

            current_y_axis_index = y_axis_unit_dict[current_unit]
            data = []
            for record in variable_data['data']:
                data.append({
                    'x': record['date'],
                    'y': record['value'],
                })

            chart['series'].append({
                'name': variable_name,
                'color': variable_data['color'],
                'type': variable_data['default_representation'],
                'unit': variable_data['unit'],
                'data': data,
                'yAxis': current_y_axis_index
            })
            chart['chart']['type'] = variable_data['default_representation'],

        charts[slugify(element_name)] = chart

    return charts

@require_http_methods(["GET"])
def get_wave_data(request):
    station_id = request.GET.get('station_id', None)
    initial_date = request.GET.get('initial_date', None)
    initial_time = request.GET.get('initial_time', None)
    range_interval = request.GET.get('range_interval', None)
    calc_interval = request.GET.get('calc_interval', None)
    component_number = request.GET.get('component_number', None)

    tz_client = request.GET.get('tz_client', None)
    tz_settings = pytz.timezone(settings.TIMEZONE_NAME)

    initial_datetime_str = initial_date+' '+initial_time
    initial_datetime = datetime_constructor.strptime(initial_datetime_str, '%Y-%m-%d %H:%M')
    initial_datetime = pytz.timezone(tz_client).localize(initial_datetime)
    initial_datetime = initial_datetime.astimezone(tz_settings)

    range_intervals = {'30min': 30, "1h": 60, "3h": 180,}

    if range_interval in range_intervals.keys():
        range_interval = range_intervals[range_interval]
    else:
        response = {"message": "Not valid interval."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)

    calc_intervals = {'1min': 1, '5min': 5, '10min': 10, '15min': 15,}

    if calc_interval in calc_intervals.keys():
        calc_interval = calc_intervals[calc_interval]
    else:
        response = {"message": "Not valid calc interval."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)

    station_id = int(station_id)
    component_number = int(component_number)

    final_datetime = initial_datetime + datetime.timedelta(minutes=range_interval)

    variable = Variable.objects.get(name="Sea Level") # Sea Level
    sea_data = HighFrequencyData.objects.filter(variable_id=variable.id,
                                                station_id=station_id,
                                                datetime__gt=initial_datetime,
                                                datetime__lte=final_datetime).order_by('datetime')

    dataset  = {"results": {}, "messages": []}

    if len(sea_data) > 0:
        dataset = create_wave_dataset(station_id, sea_data, initial_datetime,
                                      range_interval, calc_interval, component_number)

    charts = create_wave_chart(dataset)

    return JsonResponse(charts)


@require_http_methods(["GET"])
def get_equipment_inventory(request):
    template = loader.get_template('wx/maintenance_reports/equipment_inventory.html')
    context = {}

    return HttpResponse(template.render(context, request))


def get_value(variable):
    if variable is None:
        return '---'
    return variable


def equipment_classification(classification):
    if classification == 'F':
        return 'Fully Functional'
    elif classification == 'P':
        return 'Partially Functional'
    elif classification == 'N':
        return 'Not Functional'
    return None


def is_equipment_available(equipment, station):
    new_maintenance_report_eqs = MaintenanceReportEquipment.objects.filter(new_equipment_id=equipment.id).order_by('-maintenance_report__visit_date')
    old_maintenance_report_eqs = MaintenanceReportEquipment.objects.filter(old_equipment_id=equipment.id).order_by('-maintenance_report__visit_date')

    new_maintenance_report_eq = new_maintenance_report_eqs.first()
    old_maintenance_report_eq = old_maintenance_report_eqs.first()

    new_maintenance_report = new_maintenance_report_eq.maintenance_report if new_maintenance_report_eq else None
    old_maintenance_report = old_maintenance_report_eq.maintenance_report if old_maintenance_report_eq else None

    if old_maintenance_report:
        if old_maintenance_report.status != 'A' and old_maintenance_report.station_id != station.id:
            return False
    if new_maintenance_report and old_maintenance_report:
        if new_maintenance_report.visit_date >= old_maintenance_report.visit_date:
            return False
    elif new_maintenance_report:
        return False
    return True


def get_equipment_location(equipment):
    maintenance_reports_new = MaintenanceReportEquipment.objects.filter(new_equipment_id=equipment.id).order_by('-maintenance_report__visit_date')
    maintenance_reports_old = MaintenanceReportEquipment.objects.filter(old_equipment_id=equipment.id).order_by('-maintenance_report__visit_date')
    
    new_maintenance_report = maintenance_reports_new.first()
    old_maintenance_report = maintenance_reports_old.first()

    if new_maintenance_report and old_maintenance_report:
        if new_maintenance_report.maintenance_report.visit_date >= old_maintenance_report.maintenance_report.visit_date:
            return new_maintenance_report.maintenance_report.station
    elif new_maintenance_report:
        return new_maintenance_report.maintenance_report.station
    return None


@require_http_methods(["GET"])
def get_equipment_inventory_data(request):
    equipment_types = EquipmentType.objects.all()
    manufacturers = Manufacturer.objects.all()
    equipments = Equipment.objects.all().order_by('equipment_type', 'serial_number')
    funding_sources = FundingSource.objects.all()
    stations = Station.objects.all()

    equipment_list = []
    for equipment in equipments:
        try:
            equipment_type = equipment_types.get(id=equipment.equipment_type_id)
            funding_source = funding_sources.get(id=equipment.funding_source_id)
            manufacturer = manufacturers.get(id=equipment.manufacturer_id)
            station = get_equipment_location(equipment)

            equipment_dict = {
                'equipment_id': equipment.id,
                'equipment_type': equipment_type.name,
                'equipment_type_id': equipment_type.id,
                'funding_source': funding_source.name,
                'funding_source_id': funding_source.id,            
                'manufacturer': manufacturer.name,
                'manufacturer_id': manufacturer.id,
                'model': equipment.model,
                'serial_number': equipment.serial_number,
                'acquisition_date': equipment.acquisition_date,
                'first_deploy_date': equipment.first_deploy_date,
                'last_calibration_date': equipment.last_calibration_date,
                'next_calibration_date': equipment.next_calibration_date,
                'decommission_date': equipment.decommission_date,
                'last_deploy_date': equipment.last_deploy_date,
                'location': f"{station.name} - {station.code}" if station else 'Office',
                'location_id': station.id if station else None,
                'classification': equipment_classification(equipment.classification),
                'classification_id': equipment.classification,
            }
            equipment_list.append(equipment_dict)            
        except ObjectDoesNotExist:
            pass

    equipment_classifications = [
        {'name': 'Fully Functional', 'id': 'F'},
        {'name': 'Partially Functional', 'id': 'P'},
        {'name': 'Not Functional', 'id': 'N'},
    ]

    station_list = [{'name': f"{station.name} - {station.code}",
                     'id': station.id} for station in stations]

    response = {
        'equipment': equipment_list,
        'equipment_types': list(equipment_types.values()),
        'manufacturers': list(manufacturers.values()),
        'funding_sources': list(funding_sources.values()),
        'stations': station_list,
        'equipment_classifications': equipment_classifications,
    }
    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["POST"])
def create_equipment(request):
    equipment_type_id = request.GET.get('equipment_type', None)
    manufacturer_id = request.GET.get('manufacturer', None)
    funding_source_id = request.GET.get('funding_source', None)
    model = request.GET.get('model', None)
    serial_number = request.GET.get('serial_number', None)
    acquisition_date = request.GET.get('acquisition_date', None)
    first_deploy_date = request.GET.get('first_deploy_date', None)
    last_calibration_date = request.GET.get('last_calibration_date', None)
    next_calibration_date = request.GET.get('next_calibration_date', None)
    decommission_date = request.GET.get('decommission_date', None)
    location_id = request.GET.get('location', None)
    classification = request.GET.get('classification', None)
    last_deploy_date = request.GET.get('last_deploy_date', None)  

    equipment_type = EquipmentType.objects.get(id=equipment_type_id)
    manufacturer = Manufacturer.objects.get(id=manufacturer_id)   
    funding_source = FundingSource.objects.get(id=funding_source_id)

    location = None
    if location_id:
        location = Station.objects.get(id=location_id)

    try:
        equipment = Equipment.objects.get(
            equipment_type=equipment_type,
            serial_number = serial_number,
        )

        message = 'Already exist an equipment of equipment type '
        message += equipment_type.name
        message += ' and serial number '
        message += equipment.serial_number

        response = {'message': message}

        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)   

    except ObjectDoesNotExist:
        now = datetime.datetime.now()

        equipment = Equipment.objects.create(
                created_at = now,
                updated_at = now,
                equipment_type = equipment_type,
                manufacturer = manufacturer,
                funding_source = funding_source,
                model = model,
                serial_number = serial_number,
                acquisition_date = acquisition_date,
                first_deploy_date = first_deploy_date,
                last_calibration_date = last_calibration_date,
                next_calibration_date = next_calibration_date,
                decommission_date = decommission_date,
                # location = location,
                classification = classification,
                last_deploy_date = last_deploy_date,
            )

        response = {'equipment_id': equipment.id}

    return JsonResponse(response, status=status.HTTP_200_OK)   


@require_http_methods(["POST"])
def update_equipment(request):
    equipment_id = request.GET.get('equipment_id', None)
    equipment_type_id = request.GET.get('equipment_type', None)
    manufacturer_id = request.GET.get('manufacturer', None)
    funding_source_id = request.GET.get('funding_source', None)
    serial_number = request.GET.get('serial_number', None)

    equipment_type = EquipmentType.objects.get(id=equipment_type_id)
    manufacturer = Manufacturer.objects.get(id=manufacturer_id)   
    funding_source = FundingSource.objects.get(id=funding_source_id)

    try:
        equipment = Equipment.objects.get(equipment_type=equipment_type, serial_number=serial_number)

        if int(equipment_id) != equipment.id:
            message = f"Could not update. Already exist an equipment of \
                        equipment type {equipment_type.name} and serial \
                        number {equipment.serial_number}"

            response = {'message': message}

            return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)
    except ObjectDoesNotExist:
        pass

    try:
        equipment = Equipment.objects.get(id=equipment_id)

        now = datetime.datetime.now()

        equipment.updated_at = now
        equipment.equipment_type = equipment_type
        equipment.manufacturer = manufacturer
        equipment.funding_source = funding_source         
        equipment.serial_number = serial_number
        equipment.model = request.GET.get('model', None)
        equipment.acquisition_date = request.GET.get('acquisition_date', None)
        equipment.first_deploy_date = request.GET.get('first_deploy_date', None)
        equipment.last_calibration_date = request.GET.get('last_calibration_date', None)
        equipment.next_calibration_date = request.GET.get('next_calibration_date', None)
        equipment.decommission_date = request.GET.get('decommission_date', None)
        equipment.classification = request.GET.get('classification', None)
        equipment.last_deploy_date = request.GET.get('last_deploy_date', None)
        equipment.save()
        update_change_reason(equipment, f"Source of change: Front end")


        response = {}
        return JsonResponse(response, status=status.HTTP_200_OK)             

    except ObjectDoesNotExist:
        message =  "Object not found"
        response = {'message': message}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)   

    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK) 


@require_http_methods(["POST"])
def delete_equipment(request):
    equipment_id = request.GET.get('equipment_id', None)
    try:
        equipment = Equipment.objects.get(id=equipment_id)
        equipment.delete()
    except ObjectDoesNotExist:
        pass

    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["GET"])
def get_maintenance_reports(request): # Maintenance report page
    template = loader.get_template('wx/maintenance_reports/maintenance_reports.html')
    context = {}
    return HttpResponse(template.render(context, request))


@require_http_methods(["PUT"])
def get_maintenance_report_list(request):
    form_data = json.loads(request.body.decode())

    maintenance_reports = MaintenanceReport.objects.filter(visit_date__gte = form_data['start_date'], visit_date__lte = form_data['end_date'])

    response = {}
    response['maintenance_report_list'] = []

    for maintenance_report in maintenance_reports:
        if maintenance_report.status != '-':
            station, station_profile, technician, visit_type = get_maintenance_report_obj(maintenance_report)

            if station.is_automatic == form_data['is_automatic']:
                if maintenance_report.status == 'A':
                    maintenance_report_status = 'Approved'
                elif maintenance_report.status == 'P':
                    maintenance_report_status = 'Published'
                else:
                    maintenance_report_status = 'Draft'

                maintenance_report_object = {
                    'maintenance_report_id': maintenance_report.id,
                    'station_name': station.name,
                    'station_profile': station_profile.name,
                    'station_type': 'Automatic' if station.is_automatic else 'Manual',
                    'visit_date': maintenance_report.visit_date,
                    'next_visit_date': maintenance_report.next_visit_date,
                    'technician': technician.name,
                    'type_of_visit': visit_type.name,
                    'status': maintenance_report_status,
                }

                response['maintenance_report_list'].append(maintenance_report_object)

    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["GET"]) # Update maintenance report from existing report
def update_maintenance_report(request, id):
    maintenance_report = MaintenanceReport.objects.get(id=id)
    if maintenance_report.status == 'A':
        response={'message': "Approved reports can not be editable."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)
    elif maintenance_report.status == '-':
        response={'message': "This report is deleated."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)

    template = loader.get_template('wx/maintenance_reports/new_report.html')

    context = {}
    context['station_list'] = Station.objects.select_related('profile').all()
    context['visit_type_list'] = VisitType.objects.all()
    context['technician_list'] = Technician.objects.all()

    context['maintenance_report_id'] = id

    return HttpResponse(template.render(context, request))


@require_http_methods(["PUT"])
def delete_maintenance_report(request, id):
    now = datetime.datetime.now()

    maintenance_report = MaintenanceReport.objects.get(id=id)
    maintenance_report.status = '-'
    maintenance_report.save()

    response={}
    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["PUT"])
def approve_maintenance_report(request, id):
    now = datetime.datetime.now()

    maintenance_report = MaintenanceReport.objects.get(id=id)
    maintenance_report.status = 'A'
    maintenance_report.save()

    response={}
    return JsonResponse(response, status=status.HTTP_200_OK)    


@require_http_methods(["GET"])
def get_maintenance_report_view(request, id, source): # Maintenance report view
    template = loader.get_template('wx/maintenance_reports/view_report.html')

    maintenance_report = MaintenanceReport.objects.get(id=id)

    station = Station.objects.get(pk=maintenance_report.station_id)
    profile = StationProfile.objects.get(pk=station.profile_id)
    responsible_technician = Technician.objects.get(pk=maintenance_report.responsible_technician_id)
    visit_type = VisitType.objects.get(pk=maintenance_report.visit_type_id)

    maintenance_report_station_equipments = MaintenanceReportEquipment.objects.filter(maintenance_report_id=maintenance_report.id)

    maintenance_report_station_equipment_list = []

    for maintenance_report_station_equipment in maintenance_report_station_equipments:
        new_equipment_id =  maintenance_report_station_equipment.new_equipment_id
        new_equipment = Equipment.objects.get(id=new_equipment_id)
        dictionary = {'condition': maintenance_report_station_equipment.condition,
                      'component_classification': maintenance_report_station_equipment.classification,
                      'name': ' '.join([new_equipment.model, new_equipment.serial_number])
                     }
        maintenance_report_station_equipment_list.append(dictionary)

    other_technicians_ids = [maintenance_report.other_technician_1_id,
                             maintenance_report.other_technician_2_id,
                             maintenance_report.other_technician_3_id]
    other_technicians = []
    for other_technician_id in other_technicians_ids:
        if other_technician_id:
            other_technician = Technician.objects.get(id=other_technician_id)
            other_technicians.append(other_technician.name)

    other_technicians = ", ".join(other_technicians)


    context = {}

    if source == 0:
        context['source'] = 'edit'
    else:
        context['source'] = 'list'

    context['visit_summary_information'] = {
        "report_number": maintenance_report.id,
        "responsible_technician": responsible_technician.name,
        "date_of_visit": maintenance_report.visit_date,
        "date_of_next_visit": maintenance_report.next_visit_date,
        "start_time": maintenance_report.initial_time,
        "other_technicians": other_technicians,
        "end_time": maintenance_report.end_time,
        "type_of_visit": visit_type.name,
        "station_on_arrival_conditions": maintenance_report.station_on_arrival_conditions,
        "current_visit_summary": maintenance_report.current_visit_summary,
        "next_visit_summary": maintenance_report.next_visit_summary,
        "maintenance_report_status": maintenance_report.status,
    }

    context['station_information'] = {
        "station_name": station.name,
        "station_host_name": "---",
        "station_ID": station.code,
        "wigos_ID": station.wigos,
        "station_type": 'Automatic' if station.is_automatic else 'Manual',
        "station_profile": profile.name,
        "latitude": station.latitude,
        "elevation": station.elevation,
        "longitude": station.longitude,
        "district": station.region,
        "transmission_type": "---",
        "transmission_ID": "---",
        "transmission_interval": "---",
        "measurement_interval": "---",
        "data_of_first_operation": station.begin_date,
        "data_of_relocation": station.relocation_date,
    }

    context['contact_information'] = maintenance_report.contacts  

    context['equipment_records'] = maintenance_report_station_equipment_list
    # context['equipment_records'] = maintenance_report_station_component_list

    # JSON
    # return JsonResponse(context, status=status.HTTP_200_OK)

    return HttpResponse(template.render(context, request))


def get_ckeditor_config():
    ckeditor_config = {
        'toolbar': [
                ['Bold', 'Italic', 'Font'],
                ['Format', 'Styles', 'TextColor', 'BGColor', 'RemoveFormat'],
                ['JustifyLeft','JustifyCenter','JustifyRight','JustifyBlock', 'Indent', 'Outdent'],
                ['HorizontalRule', 'BulletedList'],
                ['Blockquote', 'Source', 'Link', 'Unlink', 'Image', 'Table', 'Print']
            ],
        'removeButtons': 'Image',
        'extraAllowedContent' : 'img(*){*}[*]',              
        'editorplaceholder': 'Description of station upon arribal:',
        'language': 'en',            
    }
    return ckeditor_config


def get_maintenance_report_obj(maintenance_report):
    station = Station.objects.get(id=maintenance_report.station_id)
    station_profile = StationProfile.objects.get(id=station.profile_id)
    technician = Technician.objects.get(id=maintenance_report.responsible_technician_id)
    visit_type = VisitType.objects.get(id=maintenance_report.visit_type_id)

    return station, station_profile, technician, visit_type


def get_maintenance_report_form(request): # New maintenance report form page
    template = loader.get_template('wx/maintenance_reports/new_report.html')

    context = {}
    context['station_list'] = Station.objects.select_related('profile').all()
    context['visit_type_list'] = VisitType.objects.all()
    context['technician_list'] = Technician.objects.all()

    return HttpResponse(template.render(context, request))


def get_station_contacts(station_id):
    maintenance_report_list = MaintenanceReport.objects.filter(station_id=station_id).order_by('visit_date')

    for maintenance_report in maintenance_report_list:
        if maintenance_report.contacts != '':
            return maintenance_report.contacts

    return None


def get_maintenance_report_equipment_data(maintenance_report, equipment_type, equipment_order):
    equipment_data = {
        'active_tab': 0,
        'old_equipment_id': None,
        'old_equipment_name': None,
        'new_equipment_id': None,
        'new_equipment_name': None,
        'condition': equipment_type.report_template,
        'classification': "F",
        'ckeditor_config': get_ckeditor_config()
    }

    try:
        maintenancereport_equipment = MaintenanceReportEquipment.objects.get(
                                        maintenance_report_id=maintenance_report.id,
                                        equipment_type_id=equipment_type.id,
                                        equipment_order=equipment_order)

        equipment_data['old_equipment_id'] = maintenancereport_equipment.old_equipment_id
        equipment_data['new_equipment_id'] = maintenancereport_equipment.new_equipment_id
        equipment_data['condition'] = maintenancereport_equipment.condition
        equipment_data['classification'] = maintenancereport_equipment.classification

        if maintenancereport_equipment.old_equipment_id:
            equipment = Equipment.objects.get(id=maintenancereport_equipment.old_equipment_id)
            equipment_data['old_equipment_name'] = ' '.join([equipment.model, equipment.serial_number]) 

        if maintenancereport_equipment.new_equipment_id:
            equipment = Equipment.objects.get(id=maintenancereport_equipment.new_equipment_id)
            equipment_data['new_equipment_name'] = ' '.join([equipment.model, equipment.serial_number]) 
    except ObjectDoesNotExist:
        pass

    equipment_data['active_tab'] = get_acitve_tab(equipment_data['old_equipment_id'], equipment_data['new_equipment_id'])

    return equipment_data


def get_available_equipments(equipment_type_id):
    equipments = Equipment.objects.filter(equipment_type_id=equipment_type_id)
    available_equipments = [{'id': equipment.id, 'name': ' '.join([equipment.model, equipment.serial_number])}
        for equipment in equipments if get_equipment_location(equipment) is None]

    return available_equipments


def get_available_equipments(equipment_type_id, station):
    equipments = Equipment.objects.filter(equipment_type_id=equipment_type_id)

    available_equipments = []
    for equipment in equipments:
        if is_equipment_available(equipment, station):
            available_equipments.append({'id': equipment.id, 'name': ' '.join([equipment.model, equipment.serial_number])})

    return available_equipments


def get_maintenance_report_equipment_types(maintenance_report):
    station = Station.objects.get(id=maintenance_report.station_id)
    station_profile_equipment_types = StationProfileEquipmentType.objects.filter(station_profile=station.profile_id).distinct('equipment_type')
    equipment_type_ids = station_profile_equipment_types.distinct('equipment_type').values_list('equipment_type_id', flat=True)
    equipment_types = EquipmentType.objects.filter(id__in=equipment_type_ids)

    equipment_type_list = []

    for equipment_type in equipment_types:
        dictionary = {'key':equipment_type.id,
                      'id':equipment_type.id,
                      'name': equipment_type.name,
                      'available_equipments': get_available_equipments(equipment_type.id, station),
                      'primary_equipment': get_maintenance_report_equipment_data(maintenance_report, equipment_type, 'P'),
                      'secondary_equipment': get_maintenance_report_equipment_data(maintenance_report, equipment_type, 'S'),
                      }

        equipment_type_list.append(dictionary)

    return equipment_type_list


def get_last_maintenance_report(maintenance_report):
    station_id = maintenance_report.station_id
    visit_date = maintenance_report.visit_date

    try:
        return MaintenanceReport.objects.filter(station_id=station_id,visit_date__lt=visit_date).latest('visit_date')
    except ObjectDoesNotExist:
        return None

    return last_maintenance_report    


def copy_last_maintenance_report_equipments(maintenance_report):
    last_maintenance_report = get_last_maintenance_report(maintenance_report)

    if last_maintenance_report:
        last_maintenance_report_equipments = MaintenanceReportEquipment.objects.filter(maintenance_report=last_maintenance_report)
        for maintenance_report_equipment in last_maintenance_report_equipments:
            now = datetime.datetime.now()

            equipment = Equipment.objects.get(id=maintenance_report_equipment.new_equipment_id)
            equipment_type = EquipmentType.objects.get(id=equipment.equipment_type_id)

            created_object = MaintenanceReportEquipment.objects.create(
                                created_at = now,
                                updated_at = now,                
                                maintenance_report = maintenance_report,
                                equipment_type = equipment_type,
                                equipment_order = maintenance_report_equipment.equipment_order,
                                old_equipment = equipment,
                                new_equipment = equipment,
                                condition = equipment_type.report_template,
                                classification = equipment.classification,
                            )

def get_acitve_tab(old_equipment_id, new_equipment_id):
    if old_equipment_id is None:
        return 0 #Add
    elif new_equipment_id is None:
        return 2 #Remove
    elif old_equipment_id != new_equipment_id:
        return 1 #Change
    else:
        return 0 #Update


def get_equipment_last_location(maintenance_report, equipment):
    new_maintenance_report_eqs = MaintenanceReportEquipment.objects.filter(new_equipment_id=equipment.id).order_by('-maintenance_report__visit_date')
    old_maintenance_report_eqs = MaintenanceReportEquipment.objects.filter(old_equipment_id=equipment.id).order_by('-maintenance_report__visit_date')
    
    new_maintenance_report_eq = new_maintenance_report_eqs.exclude(maintenance_report_id=maintenance_report.id).first()
    old_maintenance_report_eq = old_maintenance_report_eqs.exclude(maintenance_report_id=maintenance_report.id).first()

    new_maintenance_report = new_maintenance_report_eq.maintenance_report if new_maintenance_report_eq else None
    old_maintenance_report = old_maintenance_report_eq.maintenance_report if old_maintenance_report_eq else None

    if new_maintenance_report and old_maintenance_report:
        if new_maintenance_report.visit_date >= old_maintenance_report.visit_date:
            return new_maintenance_report.station
    elif new_maintenance_report:
        return new_maintenance_report.station

    return None


def update_maintenance_report_equipment(maintenance_report, equipment, new_classification):
    today = datetime.date.today()

    changed = False
    
    if equipment.first_deploy_date:
        last_location = get_equipment_last_location(maintenance_report, equipment)
        if last_location == maintenance_report.station:
            equipment.last_deploy_date = today
    else:
        equipment.first_deploy_date = today

    if equipment.classification != new_classification:
        equipment.classification = new_classification
    
    # equipment.changeReason = 
    # equipment.changeReason = "Source of change: Maintenance Report"
    equipment.save()
    update_change_reason(equipment, f"Source of change: Maintenance Report {maintenance_report.id}, {maintenance_report.station.name} - {maintenance_report.visit_date}")


def update_maintenance_report_equipment_type(maintenance_report, equipment_type, equipment_order, equipment_data):
    new_equipment = None
    old_equipment = None

    if equipment_data['new_equipment_id']:
        new_equipment = Equipment.objects.get(id=equipment_data['new_equipment_id'])

    if equipment_data['old_equipment_id']:
        old_equipment = Equipment.objects.get(id=equipment_data['old_equipment_id'])

    condition = equipment_data['condition']
    classification = equipment_data['classification']

    try:
        maintenance_report_equipment = MaintenanceReportEquipment.objects.get(
            maintenance_report=maintenance_report,
            equipment_type_id=equipment_type.id,
            equipment_order=equipment_order,
        )
        if old_equipment is None and new_equipment is None:
            maintenance_report_equipment.delete()
        else:
            maintenance_report_equipment.condition = condition
            maintenance_report_equipment.classification = classification
            maintenance_report_equipment.old_equipment = old_equipment
            maintenance_report_equipment.new_equipment = new_equipment
            maintenance_report_equipment.save()
            update_maintenance_report_equipment(maintenance_report, new_equipment, classification)

    except ObjectDoesNotExist:
        if old_equipment is None and new_equipment is None:
            pass
        elif old_equipment is None and new_equipment:
            maintenance_report_equipment = MaintenanceReportEquipment.objects.create(
                maintenance_report=maintenance_report,
                equipment_type=equipment_type,
                equipment_order=equipment_order,
                condition = condition,
                classification = classification,
                new_equipment = new_equipment,
                old_equipment = old_equipment,
            )
        else:
            logger.error("Error updating maintenance report equipment")


@require_http_methods(["POST"])
def update_maintenance_report_equipment_type_data(request):
    form_data = json.loads(request.body.decode())

    maintenance_report_id = form_data['maintenance_report_id'] 
    equipment_type_id = form_data['equipment_type_id'] 
    equipment_order = form_data['equipment_order'] 
    if isinstance(equipment_order, tuple):
        equipment_order = equipment_order[0]
    elif not isinstance(equipment_order, str):
        logger.error("Error in equipment order during maintenance report equipment update")
    equipment_data = {
        'new_equipment_id': form_data['new_equipment_id'], 
        'old_equipment_id': form_data['old_equipment_id'], 
        'condition': form_data['condition'], 
        'classification': form_data['classification'], 
    }

    maintenance_report = MaintenanceReport.objects.get(id=maintenance_report_id)
    equipment_type = EquipmentType.objects.get(id=equipment_type_id)
    update_maintenance_report_equipment_type(maintenance_report, equipment_type, equipment_order, equipment_data)
    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["POST"]) # Create maintenance report from sratch
def create_maintenance_report(request):
    now = datetime.datetime.now()
    form_data = json.loads(request.body.decode())

    station = Station.objects.get(id=form_data['station_id'])
    if not StationProfileEquipmentType.objects.filter(station_profile=station.profile):
        response = {"message": f"Station profile {station.profile.name} is not associated with any equipment type."}        
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)


    # Check if a maintenance report with status '-' exists and hard delete it
    maintenance_report = MaintenanceReport.objects.filter(station_id=form_data['station_id'], visit_date=form_data['visit_date'], status='-').first()
    if maintenance_report:
        maintenance_report.delete()

    # Check if a previous maintenance report is not approved
    maintenance_report = MaintenanceReport.objects.filter(station_id=form_data['station_id']).exclude(status__in=['A', '-']).first()
    if maintenance_report:
        response = {"message": f"Previous maintenance reports of {station.name} - {station.code} require approval to create a new one."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)

    # Check if a more recent maintenance report exists
    maintenance_report = MaintenanceReport.objects.filter(station_id=form_data['station_id'], visit_date__gt=form_data['visit_date']).first()
    if maintenance_report:
        response = {"message": "A more recent maintenance report already exists, and the new report must be the latest."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)

    # Create a new maintenance report if it doesn't already exist
    try:
        maintenance_report = MaintenanceReport.objects.get(station_id=form_data['station_id'], visit_date=form_data['visit_date'])
        response = {"message": "Maintenance report already exists for chosen station and date."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)
    except ObjectDoesNotExist:
        maintenance_report = MaintenanceReport.objects.create(
            created_at=now,
            updated_at=now,
            station_id=form_data['station_id'],
            responsible_technician_id=form_data['responsible_technician_id'],
            visit_type_id=form_data['visit_type_id'],
            visit_date=form_data['visit_date'],
            initial_time=form_data['initial_time'],
            contacts=get_station_contacts(form_data['station_id']),
        )

        copy_last_maintenance_report_equipments(maintenance_report)

        response = {"maintenance_report_id": maintenance_report.id}
        return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["GET"]) # Ok
def get_maintenance_report(request, id):
    maintenance_report = MaintenanceReport.objects.get(id=id)

    station, station_profile, technician, visit_type = get_maintenance_report_obj(maintenance_report)

    response = {}
    response['station_information'] = {
        "station_name": station.name,
        "station_host_name": "---",
        "station_ID": station.code,
        "wigos_ID": station.wigos,
        "station_type": 'Automatic' if station.is_automatic else 'Manual',
        "station_profile": station_profile.name,
        "latitude": station.latitude,
        "elevation": station.elevation,
        "longitude": station.longitude,
        "district": station.region,
        "transmission_type": "---",
        "transmission_ID": "---",
        "transmission_interval": "---",
        "measurement_interval": "---",
        "data_of_first_operation": station.begin_date,
        "data_of_relocation": station.relocation_date,
    }

    response["station_id"] = station.id
    response["responsible_technician"] = technician.name
    response["responsible_technician_id"] = maintenance_report.responsible_technician_id
    response["visit_date"] = maintenance_report.visit_date
    response["next_visit_date"] = maintenance_report.next_visit_date
    response["initial_time"] = maintenance_report.initial_time
    response["end_time"] = maintenance_report.end_time
    response["visit_type"] = visit_type.name
    response["visit_type_id"] = visit_type.id
    response["station_on_arrival_conditions"] = maintenance_report.station_on_arrival_conditions
    response["current_visit_summary"] = maintenance_report.current_visit_summary
    response["next_visit_summary"] = maintenance_report.next_visit_summary
    response["other_technician_1"] = maintenance_report.other_technician_1_id
    response["other_technician_2"] = maintenance_report.other_technician_2_id
    response["other_technician_3"] = maintenance_report.other_technician_3_id

    response['contacts'] = maintenance_report.contacts  
    response['equipment_types'] = get_maintenance_report_equipment_types(maintenance_report)
    response['steps'] = len(response['equipment_types'])

    if maintenance_report.data_logger_file_name is None:
        response['data_logger_file_name'] = "Upload latest data logger program"
    else:
        response['data_logger_file_name'] = maintenance_report.data_logger_file_name

    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["PUT"]) # Ok
def update_maintenance_report_condition(request, id):
    now = datetime.datetime.now()

    maintenance_report = MaintenanceReport.objects.get(id=id)
    
    form_data = json.loads(request.body.decode())
    
    maintenance_report.station_on_arrival_conditions = form_data['conditions']

    maintenance_report.updated_at = now
    maintenance_report.save()

    response={}

    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["PUT"]) # Ok
def update_maintenance_report_contacts(request, id):
    now = datetime.datetime.now()

    maintenance_report = MaintenanceReport.objects.get(id=id)

    form_data = json.loads(request.body.decode())

    maintenance_report.contacts = form_data['contacts']

    maintenance_report.updated_at = now
    maintenance_report.save()

    response={}

    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["POST"]) # Ok
def update_maintenance_report_datalogger(request, id):
    # print(request.FILES)
    if 'data_logger_file' in request.FILES:
        maintenance_report = MaintenanceReport.objects.get(id=id)

        data_logger_file = request.FILES['data_logger_file'].file
        data_logger_file_name = str(request.FILES['data_logger_file'])
        data_logger_file_content = b64encode(data_logger_file.read()).decode('utf-8')

        maintenance_report.data_logger_file = data_logger_file_content
        maintenance_report.data_logger_file_name = data_logger_file_name
        maintenance_report.updated_at = datetime.datetime.now()
        maintenance_report.save()

        response = {'data_logger_file_name', data_logger_file_name}

        return JsonResponse(response, status=status.HTTP_200_OK)

    # print("Data logger file not uploaded.")
    response={'message': "Data logger file not uploaded."}
    return JsonResponse(response, status=status.HTTP_206_PARTIAL_CONTENT)


@require_http_methods(["PUT"]) # Ok
def update_maintenance_report_summary(request, id):
    now = datetime.datetime.now()

    maintenance_report = MaintenanceReport.objects.get(id=id)

    form_data = json.loads(request.body.decode())

    if form_data['other_technician_1']:
        other_technician_1 = Technician.objects.get(id=form_data['other_technician_1'])
    else:
        other_technician_1 = None

    if form_data['other_technician_2']:
        other_technician_2 = Technician.objects.get(id=form_data['other_technician_2'])
    else:
        other_technician_2 = None

    if form_data['other_technician_3']:
        other_technician_3 = Technician.objects.get(id=form_data['other_technician_3'])    
    else:
        other_technician_3 = None

    maintenance_report.other_technician_1 = other_technician_1
    maintenance_report.other_technician_2 = other_technician_2
    maintenance_report.other_technician_3 = other_technician_3
    maintenance_report.next_visit_date = form_data['next_visit_date']
    maintenance_report.end_time = form_data['end_time']
    maintenance_report.current_visit_summary = form_data['current_visit_summary']
    maintenance_report.next_visit_summary = form_data['next_visit_summary']
    maintenance_report.status = form_data['status']

    maintenance_report.updated_at = now
    maintenance_report.save()

    response={}

    return JsonResponse(response, status=status.HTTP_200_OK)

class SpatialAnalysisView(LoginRequiredMixin, TemplateView):
    template_name = "wx/spatial_analysis.html"

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)
        context['quality_flags'] = QualityFlag.objects.all()

        return self.render_to_response(context)


@api_view(['GET'])
def raw_data_last_24h(request, station_id):
    station = Station.objects.get(pk=station_id)
    response_dict = {}

    query = f"""
        WITH data AS (
            SELECT to_char((datetime + interval '{station.utc_offset_minutes} minutes') at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS') as datetime,
                   measured,
                   variable_id
            FROM raw_data
            WHERE station_id=%s
              AND datetime >= now() - '1 day'::interval
              AND measured != {settings.MISSING_VALUE})
        SELECT datetime,
               var.name,
               var.symbol,
               unit.name,
               unit.symbol,
               measured
        FROM data
            INNER JOIN wx_variable var ON variable_id=var.id
            LEFT JOIN wx_unit unit ON var.unit_id=unit.id
        ORDER BY datetime, var.name
    """

    with connection.cursor() as cursor:

        cursor.execute(query, [station.id])

        rows = cursor.fetchall()

        for row in rows:

            if row[0] not in response_dict.keys():
                response_dict[row[0]] = []

            obj = {
                'value': row[5],
                'variable': {
                    'name': row[1],
                    'symbol': row[2],
                    'unit_name': row[3],
                    'unit_symbol': row[4]
                }
            }
            response_dict[row[0]].append(obj)

    return JsonResponse(response_dict)


class StationsMapView(LoginRequiredMixin, TemplateView):
    template_name = "wx/station_map.html"


class StationMetadataView(LoginRequiredMixin, TemplateView):
    template_name = "wx/station_metadata.html"
    model = Station

    # passing required context for watershed and region autocomplete fields
    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)

        context['station_name'] = Station.objects.values('pk', 'name')  # Fetch only pk and name

        context['is_metadata'] = True

        return context

@api_view(['GET'])
def latest_data(request, variable_id):
    result = []

    query = """
        SELECT CASE WHEN var.variable_type ilike 'code' THEN latest.last_data_code ELSE latest.last_data_value::varchar END as value,
               sta.longitude,
               sta.latitude,
               unit.symbol
        FROM wx_stationvariable latest
        INNER JOIN wx_variable var ON latest.variable_id=var.id
        INNER JOIN wx_station sta ON latest.station_id=sta.id
        LEFT JOIN wx_unit unit ON var.unit_id=unit.id
        WHERE latest.variable_id=%s 
          AND latest.last_data_value is not null
          AND latest.last_data_datetime = ( SELECT MAX(most_recent.last_data_datetime)
                                            FROM wx_stationvariable most_recent
                                            WHERE most_recent.station_id=latest.station_id 
                                                AND most_recent.last_data_value is not null)
        """

    with connection.cursor() as cursor:
        cursor.execute(query, [variable_id])

        rows = cursor.fetchall()

        for row in rows:
            obj = {
                'value': row[0],
                'longitude': row[1],
                'latitude': row[2],
                'symbol': row[3],
            }

            result.append(obj)

    return Response(result, status=status.HTTP_200_OK)


class StationImageViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    parser_class = (FileUploadParser,)
    queryset = StationImage.objects.all()
    serializer_class = serializers.StationImageSerializer

    def get_queryset(self):
        station_id = self.request.query_params.get('station_id', None)

        queryset = StationImage.objects.all()

        if station_id is not None:
            queryset = queryset.filter(station__id=station_id)

        return queryset


class StationFileViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    parser_class = (FileUploadParser,)
    queryset = StationFile.objects.all()
    serializer_class = serializers.StationFileSerializer

    def get_queryset(self):
        station_id = self.request.query_params.get('station_id', None)

        queryset = StationFile.objects.all()

        if station_id is not None:
            queryset = queryset.filter(station__id=station_id)

        return queryset


class ExtremesMeansView(LoginRequiredMixin, TemplateView):
    template_name = 'wx/products/extremes_means.html'

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)
        context['station_list'] = Station.objects.values('id', 'name', 'code')

        return self.render_to_response(context)


def get_months():
    months = {
      1: 'January',
      2: 'February',
      3: 'March',
      4: 'April',
      5: 'May',
      6: 'June',
      7: 'July',
      8: 'August',
      9: 'September',
      10: 'October',
      11: 'November',
      12: 'December',
    }

    return months


def get_interval_in_seconds(interval_id):
    if interval_id is None:
        return None
    interval = Interval.objects.get(id=int(interval_id))
    return interval.seconds


@require_http_methods(["POST"])
def update_reference_station(request):
    station_id = request.GET.get('station_id', None)
    new_reference_station_id = request.GET.get('new_reference_station_id', None)

    station = Station.objects.get(id=station_id)
    station.reference_station_id = new_reference_station_id
    station.save()

    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["POST"])
def update_global_threshold(request):
    qc_method = request.GET.get('qc_method', None)
    is_automatic = request.GET.get('is_automatic', None)
    variable_name = request.GET.get('variable_name', None)
    variable = Variable.objects.get(name=variable_name)

    is_automatic = is_automatic == "true"

    if qc_method=='range':
        range_min = request.GET.get('range_min', None)    
        range_max = request.GET.get('range_max', None)

        if is_automatic:
            variable.range_min_hourly = range_min
            variable.range_max_hourly = range_max
        else:
            variable.range_min = range_min
            variable.range_max = range_max

    elif qc_method=='step':
        step = request.GET.get('step', None)

        if is_automatic:
            variable.step_hourly = step
        else:
            variable.step = step

    elif qc_method=='persist':
        minimum_variance = request.GET.get('minimum_variance', None)    
        window = request.GET.get('window', None)

        if is_automatic:
            variable.persistence_hourly = minimum_variance
            variable.persistence_window_hourly = window
        else:
            variable.persistence = minimum_variance
            variable.persistence_window = window

    variable.save()

    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK)



@api_view(['GET', 'POST', 'PATCH', 'DELETE'])
def range_threshold_view(request): # For synop and daily data captures
    if request.method == 'GET':

        station_id = request.GET.get('station_id', None)
        variable_id_list = request.GET.get('variable_id_list', None)
        month = request.GET.get('month', None)

        variable_query_statement = ""
        month_query_statement = ""
        query_parameters = {"station_id": station_id, }

        if station_id is None:
            JsonResponse(data={"message": "'station_id' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if variable_id_list is not None:
            variable_id_list = tuple(json.loads(variable_id_list))
            variable_query_statement = "AND variable_id IN %(variable_id_list)s"
            query_parameters['variable_id_list'] = variable_id_list

        if month is not None:
            month_query_statement = "AND month = %(month)s"
            query_parameters['month'] = month

        get_range_threshold_query = f"""
            SELECT variable.id
                ,variable.name
                ,range_threshold.station_id
                ,range_threshold.range_min
                ,range_threshold.range_max
                ,range_threshold.interval   
                ,range_threshold.month
                ,TO_CHAR(TO_DATE(range_threshold.month::text, 'MM'), 'Month')
                ,range_threshold.id
            FROM wx_qcrangethreshold range_threshold
            JOIN wx_variable variable on range_threshold.variable_id = variable.id 
            WHERE station_id = %(station_id)s
            {variable_query_statement}
            {month_query_statement}
            ORDER BY variable.name, range_threshold.month
        """

        result = []
        with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
            with conn.cursor() as cursor:
                cursor.execute(get_range_threshold_query, query_parameters)

                rows = cursor.fetchall()
                for row in rows:
                    obj = {
                        'variable': {
                            'id': row[0],
                            'name': row[1]
                        },
                        'station_id': row[2],
                        'range_min': row[3],
                        'range_max': row[4],
                        'interval': row[5],
                        'month': row[6],
                        'month_desc': row[7],
                        'id': row[8],

                    }
                    result.append(obj)

        return Response(result, status=status.HTTP_200_OK)


    elif request.method == 'POST':

        station_id = request.data['station_id']
        variable_id = request.data['variable_id']
        month = request.data['month']
        interval = request.data['interval']
        range_min = request.data['range_min']
        range_max = request.data['range_max']

        if station_id is None:
            JsonResponse(data={"message": "'station_id' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if variable_id is None:
            JsonResponse(data={"message": "'variable_id' parameter cannot be null."},
                         status=status.HTTP_400_BAD_REQUEST)

        if month is None:
            JsonResponse(data={"message": "'month' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if interval is None:
            JsonResponse(data={"message": "'interval' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if range_min is None:
            JsonResponse(data={"message": "'range_min' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if range_max is None:
            JsonResponse(data={"message": "'range_max' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        post_range_threshold_query = f"""
            INSERT INTO wx_qcrangethreshold (created_at, updated_at, range_min, range_max, station_id, variable_id, interval, month) 
            VALUES (now(), now(), %(range_min)s, %(range_max)s , %(station_id)s, %(variable_id)s, %(interval)s, %(month)s)
        """
        with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
            with conn.cursor() as cursor:
                try:
                    cursor.execute(post_range_threshold_query,
                                   {'station_id': station_id, 'variable_id': variable_id, 'month': month,
                                    'interval': interval, 'range_min': range_min, 'range_max': range_max, })
                except psycopg2.errors.UniqueViolation:
                    conn.rollback()
                    return JsonResponse(data={"message": "Threshold already exists"},
                                        status=status.HTTP_400_BAD_REQUEST)

            conn.commit()
        return Response(status=status.HTTP_200_OK)


    elif request.method == 'PATCH':
        range_threshold_id = request.GET.get('id', None)
        month = request.data['month']
        interval = request.data['interval']
        range_min = request.data['range_min']
        range_max = request.data['range_max']

        if range_threshold_id is None:
            JsonResponse(data={"message": "'id' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if month is None:
            JsonResponse(data={"message": "'month' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if interval is None:
            JsonResponse(data={"message": "'interval' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if range_min is None:
            JsonResponse(data={"message": "'range_min' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        if range_max is None:
            JsonResponse(data={"message": "'range_max' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

        patch_range_threshold_query = f"""
            UPDATE wx_qcrangethreshold
            SET month = %(month)s
               ,interval = %(interval)s
               ,range_min = %(range_min)s
               ,range_max = %(range_max)s
            WHERE id = %(range_threshold_id)s
        """

        with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
            with conn.cursor() as cursor:
                try:
                    cursor.execute(patch_range_threshold_query,
                                   {'range_threshold_id': range_threshold_id, 'month': month, 'interval': interval,
                                    'range_min': range_min, 'range_max': range_max, })
                except psycopg2.errors.UniqueViolation:
                    conn.rollback()
                    return JsonResponse(data={"message": "Threshold already exists"},
                                        status=status.HTTP_400_BAD_REQUEST)

            conn.commit()
        return Response(status=status.HTTP_200_OK)


    elif request.method == 'DELETE':
        range_threshold_id = request.GET.get('id', None)

        if range_threshold_id is None:
            JsonResponse(data={"message": "'range_threshold_id' parameter cannot be null."},
                         status=status.HTTP_400_BAD_REQUEST)

        delete_range_threshold_query = f""" DELETE FROM wx_qcrangethreshold WHERE id = %(range_threshold_id)s """
        with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
            with conn.cursor() as cursor:
                try:
                    cursor.execute(delete_range_threshold_query, {'range_threshold_id': range_threshold_id})
                except:
                    conn.rollback()
                    return JsonResponse(data={"message": "Error on delete threshold"},
                                        status=status.HTTP_400_BAD_REQUEST)

            conn.commit()
        return Response(status=status.HTTP_200_OK)

    return Response([], status=status.HTTP_200_OK)


def get_range_threshold_form(request):
    template = loader.get_template('wx/quality_control/range_threshold.html')

    context = {}
    context['station_list'] = Station.objects.select_related('profile').all()
    context['station_profile_list'] = StationProfile.objects.all()
    context['station_watershed_list'] = Watershed.objects.all()
    context['station_district_list'] = AdministrativeRegion.objects.all()
    context['interval_list'] = Interval.objects.filter(seconds__gt=1).order_by('seconds')    

    return HttpResponse(template.render(context, request))


def get_range_threshold_list(station_id, variable_id, interval, is_reference=False):
    threshold_list = []
    months = get_months()
    for month_id in sorted(months.keys()):
        month = months[month_id]
        try:
            threshold = QcRangeThreshold.objects.get(station_id=station_id, variable_id=variable_id, interval=interval, month=month_id)
            threshold_entry = {
                'month': month_id,
                'min': str(threshold.range_min) if threshold.range_min is not None else '---',
                'max': str(threshold.range_max) if threshold.range_max is not None else '---',
            }
        except ObjectDoesNotExist:
            if is_reference:
                try:
                    threshold = QcRangeThreshold.objects.get(station_id=station_id, variable_id=variable_id, interval=None, month=month_id)
                    threshold_entry = {
                        'month': month_id,
                        'min': str(threshold.range_min)+'*' if threshold.range_min is not None else '---',
                        'max': str(threshold.range_max)+'*' if threshold.range_max is not None else '---',
                    }
                except ObjectDoesNotExist:
                    threshold_entry = {
                        'month': month_id,
                        'min': '---',
                        'max': '---',
                    }
            else:
                threshold_entry = {
                    'month': month_id,
                    'min': '---',
                    'max': '---',
                }
        threshold_list.append(threshold_entry)
    return threshold_list


def get_range_threshold_in_list(threshold_list, month_id):
    if threshold_list:
        for threshold_entry in threshold_list:
            if threshold_entry['month'] == month_id:
                return threshold_entry

    threshold_entry = {'month': month_id, 'min': '---', 'max': '---'}
    return threshold_entry


def format_range_thresholds(global_thresholds, reference_thresholds, custom_thresholds, variable_name):
    months = get_months()

    formated_thresholds = []
    for month_id in sorted(months.keys()):
        month_name = months[month_id]

        custom_entry = get_range_threshold_in_list(custom_thresholds, month_id)
        reference_entry = get_range_threshold_in_list(reference_thresholds, month_id)

        formated_threshold = {
            'variable_name': variable_name,
            'month_name': month_name,
            'global':{
                'children':{
                    'g_min': global_thresholds['min'],
                    'g_max': global_thresholds['max'],
                }
            },
            'reference':{
                'children':{
                    'r_min': reference_entry['min'],
                    'r_max': reference_entry['max'],
                }
            },
            'custom':{
                'children':{
                    'c_min': custom_entry['min'],
                    'c_max': custom_entry['max'],
                }
            }
        }
        formated_thresholds.append(formated_threshold)

    return formated_thresholds


@require_http_methods(["GET"])
def get_range_threshold(request):
    station_id = request.GET.get('station_id', None)
    if station_id is None:
        response = {'message': "Field Station can not be empty."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)

    
    variable_ids = request.GET.get('variable_ids', None)
    if variable_ids is None:
        response = {'message': "Field Variables can not be empty."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST) 

    interval_id = request.GET.get('interval_id', None)
    # if interval_id is None:
    #     response = {'message': "Field Measurement Interval can not be empty."}
    #     return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)    

    station = Station.objects.get(id=int(station_id))
    variable_ids = [int(variable_id) for variable_id in variable_ids.split(",")]
    interval_seconds = get_interval_in_seconds(interval_id)

    reference_station_id = station.reference_station_id
    if reference_station_id:
        reference_station = Station.objects.get(id=station.reference_station_id)
        reference_station_name = reference_station.name+' - '+reference_station.code
    else:
        reference_station = None
        reference_station_name = None

    data = {
        'reference_station_id': reference_station_id,
        'reference_station_name': reference_station_name,
        'variable_data': {},
    }

    for variable_id in variable_ids:
        variable = Variable.objects.get(id=variable_id)

        custom_thresholds = get_range_threshold_list(station.id, variable.id, interval_seconds, is_reference=False)

        if reference_station:
            reference_thresholds = get_range_threshold_list(reference_station.id, variable.id, interval_seconds, is_reference=True)
        else:
            reference_thresholds = None

        global_thresholds = {}
        if station.is_automatic:
            global_thresholds['min'] = variable.range_min_hourly
            global_thresholds['max'] = variable.range_max_hourly
        else:
            global_thresholds['min'] = variable.range_min
            global_thresholds['max'] = variable.range_max

        global_thresholds['min'] = '---' if global_thresholds['min'] is None else str(global_thresholds['min'])
        global_thresholds['max'] = '---' if global_thresholds['max'] is None else str(global_thresholds['max'])

        formated_thresholds = format_range_thresholds(global_thresholds, reference_thresholds, custom_thresholds, variable.name)

        data['variable_data'][variable.name] = formated_thresholds;

    response = {'data': data}
    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["POST"])
def update_range_threshold(request):
    months = get_months()
    months_ids = {v: k for k, v in months.items()}

    new_min = request.GET.get('new_min', None)    
    new_max = request.GET.get('new_max', None)
    interval_id = request.GET.get('interval_id', None)
    station_id = request.GET.get('station_id', None)    
    variable_name = request.GET.get('variable_name', None)    
    month_name = request.GET.get('month_name', None)


    station = Station.objects.get(id=station_id)
    variable = Variable.objects.get(name=variable_name)
    month_id = months_ids[month_name]
    interval_seconds = get_interval_in_seconds(interval_id)

    qcrangethreshold, created = QcRangeThreshold.objects.get_or_create(station_id=station.id, variable_id=variable.id, month=month_id, interval=interval_seconds)

    qcrangethreshold.range_min = new_min
    qcrangethreshold.range_max = new_max

    qcrangethreshold.save()

    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["POST"])
def delete_range_threshold(request):
    months = get_months()
    months_ids = {v: k for k, v in months.items()}

    interval_id = request.GET.get('interval_id', None)
    station_id = request.GET.get('station_id', None)    
    variable_name = request.GET.get('variable_name', None)    
    month_name = request.GET.get('month_name', None)

    station = Station.objects.get(id=station_id)
    variable = Variable.objects.get(name=variable_name)
    month_id = months_ids[month_name]
    interval_seconds = get_interval_in_seconds(interval_id)

    try:
        qcrangethreshold = QcRangeThreshold.objects.get(station_id=station.id, variable_id=variable.id, month=month_id, interval=interval_seconds)
        qcrangethreshold.delete()
    except ObjectDoesNotExist:
        pass

    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK)


def get_step_threshold_form(request):
    template = loader.get_template('wx/quality_control/step_threshold.html')

    context = {}
    context['station_list'] = Station.objects.select_related('profile').all()
    context['station_profile_list'] = StationProfile.objects.all()
    context['station_watershed_list'] = Watershed.objects.all()
    context['station_district_list'] = AdministrativeRegion.objects.all()
    context['interval_list'] = Interval.objects.filter(seconds__gt=1).order_by('seconds')    

    return HttpResponse(template.render(context, request))


def get_step_threshold_entry(station_id, variable_id, interval, is_reference=False):
    try:
        threshold = QcStepThreshold.objects.get(station_id=station_id, variable_id=variable_id, interval=interval)
        threshold_entry = {
            'min': str(threshold.step_min) if threshold.step_min is not None else '---',
            'max': str(threshold.step_max) if threshold.step_max is not None else '---',
        }        
    except ObjectDoesNotExist:
        if is_reference:
            try:
                threshold = QcStepThreshold.objects.get(station_id=station_id, variable_id=variable_id, interval=None)
                threshold_entry = {
                    'min': str(threshold.step_min)+'*' if threshold.step_min is not None else '---',
                    'max': str(threshold.step_max)+'*' if threshold.step_max is not None else '---',
                }
            except ObjectDoesNotExist:
                threshold_entry = {
                    'min': '---',
                    'max': '---',
                }
        else:
            threshold_entry = {
                'min': '---',
                'max': '---',
            }        

    return threshold_entry


def format_step_thresholds(global_thresholds, reference_thresholds, custom_thresholds, variable_name):
    formated_threshold = {
        'variable_name': variable_name,
        'global':{
            'children':{
                'g_min': global_thresholds['min'],
                'g_max': global_thresholds['max'],
            }
        },
        'reference':{
            'children':{
                'r_min': reference_thresholds['min'],
                'r_max': reference_thresholds['max'],
            }
        },
        'custom':{
            'children':{
                'c_min': custom_thresholds['min'],
                'c_max': custom_thresholds['max'],
            }
        }
    }
    return [formated_threshold]


@require_http_methods(["GET"])
def get_step_threshold(request):
    station_id = request.GET.get('station_id', None)
    if station_id is None:
        response = {'message': "Field Station can not be empty."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)
    
    variable_ids = request.GET.get('variable_ids', None)
    if variable_ids is None:
        response = {'message': "Field Variables can not be empty."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST) 

    interval_id = request.GET.get('interval_id', None)
    # if interval_id is None:
    #     response = {'message': "Field Measurement Interval can not be empty."}
    #     return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)    

    station = Station.objects.get(id=int(station_id))
    variable_ids = [int(variable_id) for variable_id in variable_ids.split(",")]
    interval_seconds = get_interval_in_seconds(interval_id)

    reference_station_id = station.reference_station_id
    if reference_station_id:
        reference_station = Station.objects.get(id=station.reference_station_id)
        reference_station_name = reference_station.name+' - '+reference_station.code
    else:
        reference_station = None
        reference_station_name = None

    data = {
        'reference_station_id': reference_station_id,
        'reference_station_name': reference_station_name,
        'variable_data': {},
    }

    for variable_id in variable_ids:
        variable = Variable.objects.get(id=variable_id)

        custom_thresholds = get_step_threshold_entry(station.id, variable.id, interval_seconds, is_reference=False)
        
        if reference_station:
            reference_thresholds = get_step_threshold_entry(reference_station.id, variable.id, interval_seconds, is_reference=True)
        else:
            reference_thresholds = {'min': '---', 'max': '---'}

        global_thresholds = {}
        if station.is_automatic:
            global_thresholds['min'] = -variable.step_hourly if variable.step_hourly else variable.step_hourly
            global_thresholds['max'] = variable.step_hourly
        else:
            global_thresholds['min'] = -variable.step if variable.step else variable.step
            global_thresholds['max'] = variable.step

        global_thresholds['min'] = '---' if global_thresholds['min'] is None else str(global_thresholds['min'])
        global_thresholds['max'] = '---' if global_thresholds['max'] is None else str(global_thresholds['max'])

        formated_thresholds = format_step_thresholds(global_thresholds, reference_thresholds, custom_thresholds, variable.name)

        data['variable_data'][variable.name] = formated_thresholds;

    response = {'data': data}
    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["POST"])
def update_step_threshold(request):
    new_min = request.GET.get('new_min', None)    
    new_max = request.GET.get('new_max', None)
    interval_id = request.GET.get('interval_id', None)
    station_id = request.GET.get('station_id', None)    
    variable_name = request.GET.get('variable_name', None)    

    station = Station.objects.get(id=station_id)
    variable = Variable.objects.get(name=variable_name)
    interval_seconds = get_interval_in_seconds(interval_id)

    qcstepthreshold, created = QcStepThreshold.objects.get_or_create(station_id=station.id, variable_id=variable.id, interval=interval_seconds)

    qcstepthreshold.step_min = new_min
    qcstepthreshold.step_max = new_max

    qcstepthreshold.save()

    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["POST"])
def delete_step_threshold(request):
    interval_id = request.GET.get('interval_id', None)
    station_id = request.GET.get('station_id', None)    
    variable_name = request.GET.get('variable_name', None)    

    station = Station.objects.get(id=station_id)
    variable = Variable.objects.get(name=variable_name)
    interval_seconds = get_interval_in_seconds(interval_id)

    try:
        qcstepthreshold = QcStepThreshold.objects.get(station_id=station.id, variable_id=variable.id, interval=interval_seconds)        
        qcstepthreshold.delete()
    except ObjectDoesNotExist:
        pass

    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK)


def get_persist_threshold_form(request):
    template = loader.get_template('wx/quality_control/persist_threshold.html')

    context = {}
    context['station_list'] = Station.objects.select_related('profile').all()
    context['station_profile_list'] = StationProfile.objects.all()
    context['station_watershed_list'] = Watershed.objects.all()
    context['station_district_list'] = AdministrativeRegion.objects.all()
    context['interval_list'] = Interval.objects.filter(seconds__gt=1).order_by('seconds')    

    return HttpResponse(template.render(context, request))


def get_persist_threshold_entry(station_id, variable_id, interval, is_reference=False):
    try:
        threshold = QcPersistThreshold.objects.get(station_id=station_id, variable_id=variable_id, interval=interval)
        threshold_entry = {
            'var': str(threshold.minimum_variance) if threshold.minimum_variance is not None else '---',
            'win': str(threshold.window) if threshold.window is not None else '---',
        }        
    except ObjectDoesNotExist:
        if is_reference:
            try:
                threshold = QcPersistThreshold.objects.get(station_id=station_id, variable_id=variable_id, interval=None)
                threshold_entry = {
                    'var': str(threshold.minimum_variance)+'*' if threshold.minimum_variance is not None else '---',
                    'win': str(threshold.window)+'*' if threshold.window is not None else '---',
                }
            except ObjectDoesNotExist:
                threshold_entry = {
                    'var': '---',
                    'win': '---',
                }
        else:
            threshold_entry = {
                'var': '---',
                'win': '---',
            }        

    return threshold_entry


def format_persist_thresholds(global_thresholds, reference_thresholds, custom_thresholds, variable_name):
    formated_threshold = {
        'variable_name': variable_name,
        'global':{
            'children':{
                'g_var': global_thresholds['var'],
                'g_win': global_thresholds['win'],
            }
        },
        'reference':{
            'children':{
                'r_var': reference_thresholds['var'],
                'r_win': reference_thresholds['win'],
            }
        },
        'custom':{
            'children':{
                'c_var': custom_thresholds['var'],
                'c_win': custom_thresholds['win'],
            }
        }
    }
    return [formated_threshold]


@require_http_methods(["GET"])
def get_persist_threshold(request):
    station_id = request.GET.get('station_id', None)
    if station_id is None:
        response = {'message': "Field Station can not be empty."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)
    
    variable_ids = request.GET.get('variable_ids', None)
    if variable_ids is None:
        response = {'message': "Field Variables can not be empty."}
        return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST) 

    interval_id = request.GET.get('interval_id', None)
    # if interval_id is None:
    #     response = {'message': "Field Measurement Interval can not be empty."}
    #     return JsonResponse(response, status=status.HTTP_400_BAD_REQUEST)    

    station = Station.objects.get(id=int(station_id))
    variable_ids = [int(variable_id) for variable_id in variable_ids.split(",")]
    interval_seconds = get_interval_in_seconds(interval_id)

    reference_station_id = station.reference_station_id
    if reference_station_id:
        reference_station = Station.objects.get(id=station.reference_station_id)
        reference_station_name = reference_station.name+' - '+reference_station.code
    else:
        reference_station = None
        reference_station_name = None

    data = {
        'reference_station_id': reference_station_id,
        'reference_station_name': reference_station_name,
        'variable_data': {},
    }

    for variable_id in variable_ids:
        variable = Variable.objects.get(id=variable_id)

        custom_thresholds = get_persist_threshold_entry(station.id, variable.id, interval_seconds, is_reference=False)
        
        if reference_station:
            reference_thresholds = get_persist_threshold_entry(reference_station.id, variable.id, interval_seconds, is_reference=True)
        else:
            reference_thresholds = {'var': '---', 'win': '---'}

        global_thresholds = {}
        if station.is_automatic:
            global_thresholds['var'] = variable.persistence_hourly
            global_thresholds['win'] = variable.persistence_window_hourly
        else:
            global_thresholds['var'] = variable.persistence
            global_thresholds['win'] = variable.persistence_window

        global_thresholds['var'] = '---' if global_thresholds['var'] is None else str(global_thresholds['var'])
        global_thresholds['win'] = '---' if global_thresholds['win'] is None else str(global_thresholds['win'])

        formated_thresholds = format_persist_thresholds(global_thresholds, reference_thresholds, custom_thresholds, variable.name)

        data['variable_data'][variable.name] = formated_thresholds;

    response = {'data': data}
    return JsonResponse(response, status=status.HTTP_200_OK)    


@require_http_methods(["POST"])
def update_persist_threshold(request):
    new_var = request.GET.get('new_var', None)    
    new_win = request.GET.get('new_win', None)
    station_id = request.GET.get('station_id', None)    
    variable_name = request.GET.get('variable_name', None)    
    interval_id = request.GET.get('interval_id', None)

    station = Station.objects.get(id=station_id)
    variable = Variable.objects.get(name=variable_name)
    interval_seconds = get_interval_in_seconds(interval_id)

    try:
        qcpersistthreshold = QcPersistThreshold.objects.get(station_id=station.id, variable_id=variable.id, interval=interval_seconds)
    except ObjectDoesNotExist:
        qcpersistthreshold = QcPersistThreshold.objects.create(station_id=station.id, variable_id=variable.id, interval=interval_seconds, minimum_variance=new_var, window=new_win)

    qcpersistthreshold.save()

    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK)


@require_http_methods(["POST"])
def delete_persist_threshold(request):
    station_id = request.GET.get('station_id', None)    
    variable_name = request.GET.get('variable_name', None)    
    interval_id = request.GET.get('interval_id', None)

    station = Station.objects.get(id=station_id)
    variable = Variable.objects.get(name=variable_name)
    interval_seconds = get_interval_in_seconds(interval_id)

    try:
        qcpersistthreshold = QcPersistThreshold.objects.get(station_id=station.id, variable_id=variable.id, interval=interval_seconds)        
        qcpersistthreshold.delete()
    except ObjectDoesNotExist:
        pass

    response = {}
    return JsonResponse(response, status=status.HTTP_200_OK)


@api_view(['GET'])
def daily_means_data_view(request):
    station_id = request.GET.get('station_id', None)
    month = request.GET.get('month', None)
    variable_id_list = request.GET.get('variable_id_list', None)
    begin_year = request.GET.get('begin_year', None)
    end_year = request.GET.get('end_year', None)
    filter_year_query = ""
    filter_year_query_avg = ""
    period = "All years"

    if station_id is None:
        JsonResponse(data={"message": "'station_id' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

    if month is None:
        JsonResponse(data={"message": "'month' parameter cannot be null."}, status=status.HTTP_400_BAD_REQUEST)

    if variable_id_list is not None:
        variable_id_list = json.loads(variable_id_list)
    else:
        JsonResponse(data={"message": "'variable_id_list' parameter cannot be null."},
                     status=status.HTTP_400_BAD_REQUEST)

    if begin_year is not None and end_year is not None:
        try:
            filter_year_query = "AND EXTRACT(YEAR from day) >= %(begin_year)s AND EXTRACT(YEAR from day) <= %(end_year)s"
            period = f"{begin_year} - {end_year}"

            begin_year = int(begin_year)
            end_year = int(end_year)
        except ValueError:
            JsonResponse(data={"message": "Invalid 'begin_year' or 'end_year' parameters."},
                         status=status.HTTP_400_BAD_REQUEST)

    month = int(month)
    res = {}
    variable_dict = {}
    variable_symbol_dict = {}
    for variable_id in variable_id_list:
        query_params_dict = {"station_id": station_id, "month": month, "variable_id": variable_id,
                             "begin_year": begin_year, "end_year": end_year}
        variable = Variable.objects.get(pk=variable_id)

        variable_symbol_dict[variable.symbol] = variable.name
        aggregation_type = variable.sampling_operation.name if variable.sampling_operation is not None else None
        data_dict = {}
        summary_dict = {}
        colspan = 1
        headers = ['Average']
        columns = ['value']

        if aggregation_type == 'Accumulation':
            colspan = 3
            headers = ['Greatest', 'Year', 'Years']
            columns = ['agg_value', 'year', 'years']

            with connection.cursor() as cursor:
                cursor.execute(f"""
                    SELECT data.day
                          ,data.sum_value
                          ,data.year
                          ,data.years
                    FROM (SELECT EXTRACT(DAY from day) as day
                                ,sum_value
                                ,EXTRACT(YEAR from day) as year
                                ,RANK () OVER (PARTITION BY EXTRACT(DAY from day) ORDER BY sum_value DESC) as rank
                                ,count(1) OVER (PARTITION BY EXTRACT(DAY from day)) as years
                         FROM daily_summary
                         WHERE station_id  = %(station_id)s
                           AND EXTRACT(MONTH from day) = %(month)s
                           AND variable_id = %(variable_id)s
                           {filter_year_query}) data
                    WHERE data.rank = 1
                """, query_params_dict)
                rows = cursor.fetchall()

                if len(rows) > 0:
                    df = pd.DataFrame(data=rows, columns=("day", "sum_value", "year", "years"))
                    for index, row in df.iterrows():
                        data_dict[int(row['day'])] = {"agg_value": round(row['sum_value'], 2), "year": row['year'],
                                                      "years": row['years']}

                    max_row = df.loc[df["sum_value"].idxmax()]
                    summary_dict = {"agg_value": round(max_row['sum_value'], 2), "year": max_row['year']}


        elif aggregation_type == 'Maximum':
            colspan = 4
            headers = ['Average', 'Extreme', 'Year', 'Years']
            columns = ['value', 'agg_value', 'year', 'years']

            with connection.cursor() as cursor:
                cursor.execute(f"""
                    SELECT data.day
                          ,summary.value
                          ,data.max_value
                          ,data.year
                          ,data.years
                    FROM (SELECT EXTRACT(DAY from day) as day
                                ,max_value
                                ,EXTRACT(YEAR from day) as year
                                ,RANK () OVER (PARTITION BY EXTRACT(DAY from day) ORDER BY max_value DESC) as rank
                                ,count(1) OVER (PARTITION BY EXTRACT(DAY from day)) as years
                         FROM daily_summary
                         WHERE station_id  = %(station_id)s
                           AND EXTRACT(MONTH from day) = %(month)s
                           AND variable_id = %(variable_id)s
                           {filter_year_query}) data,
                        (SELECT EXTRACT(DAY from day) as day
                                ,avg(max_value) as value
                         FROM daily_summary
                         WHERE station_id  = %(station_id)s
                           AND EXTRACT(MONTH from day) = %(month)s
                           AND variable_id = %(variable_id)s
                           {filter_year_query}
                         GROUP BY 1) summary
                    WHERE data.rank = 1
                    AND summary.day = data.day
                """, query_params_dict)
                rows = cursor.fetchall()

                if len(rows) > 0:
                    df = pd.DataFrame(data=rows, columns=("day", "value", "max_value", "year", "years"))
                    for index, row in df.iterrows():
                        data_dict[int(row['day'])] = {"value": round(row['value'], 2),
                                                      "agg_value": round(row['max_value'], 2), "year": row['year'],
                                                      "years": row['years']}

                    max_row = df.loc[df["max_value"].idxmax()]
                    summary_dict = {"value": round(df["value"].mean(), 2), "agg_value": round(max_row['max_value'], 2),
                                    "year": max_row['year']}

        elif aggregation_type == 'Minimum':
            headers = ['Average', 'Extreme', 'Year', 'Years']
            columns = ['value', 'agg_value', 'year', 'years']
            colspan = 4
            with connection.cursor() as cursor:
                cursor.execute(f"""
                    SELECT data.day
                          ,summary.value
                          ,data.min_value
                          ,data.year
                          ,data.years
                    FROM (SELECT EXTRACT(DAY from day) as day
                                ,min_value
                                ,EXTRACT(YEAR from day) as year
                                ,RANK () OVER (PARTITION BY EXTRACT(DAY from day) ORDER BY min_value ASC) as rank
                                ,count(1) OVER (PARTITION BY EXTRACT(DAY from day)) as years
                         FROM daily_summary
                         WHERE station_id  = %(station_id)s
                           AND EXTRACT(MONTH from day) = %(month)s
                           AND variable_id = %(variable_id)s
                           {filter_year_query}) data,
                        (SELECT EXTRACT(DAY from day) as day
                                ,avg(min_value) as value
                         FROM daily_summary
                         WHERE station_id  = %(station_id)s
                           AND EXTRACT(MONTH from day) = %(month)s
                           AND variable_id = %(variable_id)s
                           {filter_year_query}
                         GROUP BY 1) summary
                    WHERE data.rank = 1
                    AND summary.day = data.day
                """, query_params_dict)
                rows = cursor.fetchall()

                if len(rows) > 0:
                    df = pd.DataFrame(data=rows, columns=("day", "value", "min_value", "year", "years"))
                    for index, row in df.iterrows():
                        data_dict[int(row['day'])] = {"value": round(row['value'], 2),
                                                      "agg_value": round(row['min_value'], 2), "year": row['year'],
                                                      "years": row['years']}

                    max_row = df.loc[df["min_value"].idxmin()]
                    summary_dict = {"value": round(df["value"].mean(), 2), "agg_value": round(max_row['min_value'], 2),
                                    "year": max_row['year']}

        else:
            with connection.cursor() as cursor:
                cursor.execute(f"""
                    SELECT EXTRACT(DAY from day)
                          ,avg(avg_value)
                    FROM daily_summary data
                    WHERE station_id = %(station_id)s
                    AND EXTRACT(MONTH from day) = %(month)s
                    AND variable_id = %(variable_id)s
                    {filter_year_query}
                    GROUP BY 1
                """, query_params_dict)
                rows = cursor.fetchall()

                if len(rows) > 0:
                    for row in rows:
                        day = int(row[0])
                        value = round(row[1], 2)
                        data_dict[day] = {"value": value}

                    df = pd.DataFrame(data=rows, columns=("day", "value"))
                    summary_dict = {"value": round(df["value"].mean(), 2)}

        variable_dict[variable_id] = {
            'metadata': {
                "name": variable.symbol,
                "id": variable.id,
                "unit": variable.unit.name if variable.unit is not None else "",
                "unit_symbol": variable.unit.symbol if variable.unit is not None else "",
                "aggregation": aggregation_type,
                "colspan": colspan,
                "headers": headers,
                "columns": columns
            },
            'data': data_dict,
            'summary': summary_dict,
        }

    res['variables'] = variable_dict
    station = Station.objects.get(pk=station_id)
    res['station'] = {
        "name": station.name,
        "district": station.region,
        "latitude": station.latitude,
        "longitude": station.longitude,
        "elevation": station.elevation,
        "variables": variable_symbol_dict,
    }

    res['params'] = {
        "month": month,
        "period": period,
    }

    return JsonResponse(res, status=status.HTTP_200_OK)


class DataInventoryView(LoginRequiredMixin, TemplateView):
    template_name = "wx/data_inventory.html"

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)

        context['variable_list'] = Variable.objects.all()

        return self.render_to_response(context)


@api_view(['GET'])
def get_data_inventory(request):
    start_year = request.GET.get('start_date', None)
    end_year = request.GET.get('end_date', None)
    is_automatic = request.GET.get('is_automatic', None)

    result = []

    query = """
       SELECT EXTRACT('YEAR' from station_data.datetime)
              ,station.id
              ,station.name
              ,station.code
              ,station.is_automatic
              ,station.begin_date
              ,station.watershed
              ,TRUNC(AVG(station_data.record_count_percentage)::numeric, 2)
        FROM wx_stationdataminimuminterval AS station_data
        JOIN wx_station AS station ON station.id = station_data.station_id
        WHERE EXTRACT('YEAR' from station_data.datetime) >= %(start_year)s
          AND EXTRACT('YEAR' from station_data.datetime) <  %(end_year)s
          AND station.is_automatic = %(is_automatic)s
        GROUP BY 1, station.id
        ORDER BY station.watershed, station.name
    """

    with connection.cursor() as cursor:
        cursor.execute(query, {"start_year": start_year, "end_year": end_year, "is_automatic": is_automatic})
        rows = cursor.fetchall()

        for row in rows:
            obj = {
                'year': row[0],
                'station': {
                    'id': row[1],
                    'name': row[2],
                    'code': row[3],
                    'is_automatic': row[4],
                    'begin_date': row[5],
                    'watershed': row[6],
                },
                'percentage': row[7],
            }
            result.append(obj)

    return Response(result, status=status.HTTP_200_OK)


@api_view(['GET'])
def get_data_inventory_by_station(request):
    start_year = request.GET.get('start_date', None)
    end_year = request.GET.get('end_date', None)
    station_id: list = request.GET.get('station_id', None)
    record_limit = request.GET.get('record_limit', None)

    if station_id is None or len(station_id) == 0:
        return JsonResponse({"message": "\"station_id\" must not be null"}, status=status.HTTP_400_BAD_REQUEST)

    record_limit_lexical = ""
    if record_limit is not None:
        record_limit_lexical = f"LIMIT {record_limit}"

    result = []
    query = f"""
       WITH variable AS (
            SELECT variable.id, variable.name 
            FROM wx_variable AS variable
            JOIN wx_stationvariable AS station_variable ON station_variable.variable_id = variable.id
            WHERE station_variable.station_id = %(station_id)s
            ORDER BY variable.name
            {record_limit_lexical}
        )
        SELECT EXTRACT('YEAR' from station_data.datetime)
              ,limited_variable.id
              ,limited_variable.name
              ,TRUNC(AVG(station_data.record_count_percentage)::numeric, 2)
        FROM wx_stationdataminimuminterval AS station_data
        JOIN variable AS limited_variable ON limited_variable.id = station_data.variable_id
        JOIN wx_station station ON station_data.station_id = station.id
        WHERE EXTRACT('YEAR' from station_data.datetime) >= %(start_year)s
          AND EXTRACT('YEAR' from station_data.datetime) <  %(end_year)s
          AND station_data.station_id = %(station_id)s
        GROUP BY 1, limited_variable.id, limited_variable.name
        ORDER BY 1, limited_variable.name
    """

    with connection.cursor() as cursor:
        cursor.execute(query, {"start_year": start_year, "end_year": end_year, "station_id": station_id})
        rows = cursor.fetchall()

        for row in rows:
            obj = {
                'year': row[0],
                'variable': {
                    'id': row[1],
                    'name': row[2],
                },
                'percentage': row[3],
            }
            result.append(obj)

    return Response(result, status=status.HTTP_200_OK)


@api_view(['GET'])
def get_station_variable_month_data_inventory(request):
    year = request.GET.get('year', None)
    station_id = request.GET.get('station_id', None)

    if station_id is None:
        return JsonResponse({"message": "Invalid request. Station id must be provided"},
                            status=status.HTTP_400_BAD_REQUEST)

    result = []
    query = """
        SELECT EXTRACT('MONTH' FROM station_data.datetime) AS month
              ,variable.id
              ,variable.name
              ,measurementvariable.name
              ,TRUNC(AVG(station_data.record_count_percentage)::numeric, 2)
        FROM wx_stationdataminimuminterval AS station_data
        JOIN wx_variable variable ON station_data.variable_id=variable.id
        LEFT JOIN wx_measurementvariable measurementvariable ON measurementvariable.id = variable.measurement_variable_id
        WHERE EXTRACT('YEAR' from station_data.datetime) = %(year)s
          AND station_data.station_id = %(station_id)s
        GROUP BY 1, variable.id, variable.name, measurementvariable.name
    """

    with connection.cursor() as cursor:
        cursor.execute(query, {"year": year, "station_id": station_id})
        rows = cursor.fetchall()

        for row in rows:
            obj = {
                'month': row[0],
                'variable': {
                    'id': row[1],
                    'name': row[2],
                    'measurement_variable_name': row[3] if row[3] is None else row[3].lower().replace(' ', '-'),
                },
                'percentage': row[4],
            }
            result.append(obj)

    return Response(result, status=status.HTTP_200_OK)


@api_view(['GET'])
def get_station_variable_day_data_inventory(request):
    year = request.GET.get('year', None)
    month = request.GET.get('month', None)
    station_id = request.GET.get('station_id', None)
    variable_id = request.GET.get('variable_id', None)

    if station_id is None:
        return JsonResponse({"message": "Invalid request. Station id must be provided"},
                            status=status.HTTP_400_BAD_REQUEST)

    query = """
         WITH data AS (
             SELECT EXTRACT('DAY' FROM station_data.datetime) AS day
                   ,EXTRACT('DOW' FROM station_data.datetime) AS dow
                   ,TRUNC(station_data.record_count_percentage::numeric, 2) as percentage
                   ,station_data.record_count
                   ,station_data.ideal_record_count
                   ,(select COUNT(1) from raw_data rd where rd.station_id = station_data.station_id and rd.variable_id = station_data.variable_id and rd.datetime between station_data.datetime  and station_data.datetime + '1 DAY'::interval and coalesce(rd.manual_flag, rd.quality_flag) in (1, 4)) qc_passed_amount
                   ,(select COUNT(1) from raw_data rd where rd.station_id = station_data.station_id and rd.variable_id = station_data.variable_id and rd.datetime between station_data.datetime  and station_data.datetime + '1 DAY'::interval) qc_amount
            FROM wx_stationdataminimuminterval AS station_data
            WHERE EXTRACT('YEAR' from station_data.datetime) = %(year)s
              AND EXTRACT('MONTH' from station_data.datetime) = %(month)s 
              AND station_data.station_id = %(station_id)s
              AND station_data.variable_id = %(variable_id)s
            ORDER BY station_data.datetime)
         SELECT available_days.custom_day
               ,data.dow
               ,COALESCE(data.percentage, 0) AS percentage
               ,COALESCE(data.record_count, 0) AS record_count
               ,COALESCE(data.ideal_record_count, 0) AS ideal_record_count
               ,case when data.qc_amount = 0 then 0 
                     else TRUNC((data.qc_passed_amount / data.qc_amount::numeric) * 100, 2) end as qc_passed_percentage
         FROM (SELECT custom_day FROM unnest( ARRAY[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31] ) AS custom_day) AS available_days
         LEFT JOIN data ON data.day = available_days.custom_day;
         
    """

    days = []
    day_with_data = None
    with connection.cursor() as cursor:
        cursor.execute(query, {"year": year, "station_id": station_id, "month": month, "variable_id": variable_id})
        rows = cursor.fetchall()

        for row in rows:
            obj = {
                'day': row[0],
                'dow': row[1],
                'percentage': row[2],
                'record_count': row[3],
                'ideal_record_count': row[4],
                'qc_passed_percentage': row[5],
            }

            if row[1] is not None and day_with_data is None:
                day_with_data = obj
            days.append(obj)

    if day_with_data is None:
        return JsonResponse({"message": "No data found"},
                            status=status.HTTP_404_NOT_FOUND)

    for day in days:
        current_day = day.get('day', None)
        current_dow = day.get('dow', None)
        if current_dow is None:
            day_with_data_day = day_with_data.get('day', None)
            day_with_data_dow = day_with_data.get('dow', None)
            day_difference = current_day - day_with_data_day
            day["dow"] = (day_difference + day_with_data_dow) % 7

    return Response(days, status=status.HTTP_200_OK)


class UserInfo(views.APIView):
    permission_classes = (IsAuthenticated,)

    def get(self, request):
        username = request.user.username
        return Response({'username': username})


class AvailableDataView(views.APIView):
    permission_classes = (IsAuthenticated,)

    def post(self, request):
        try:
            json_data = json.loads(request.body)

            initial_date = json_data['initial_date']
            final_date = json_data['final_date']
            data_source = json_data['data_source']
            sv_list = [(row['station_id'], row['variable_id']) for row in json_data['series']]

            if (data_source=="monthly_summary"):
                initial_date = initial_date[:-2]+'01'
                final_date = final_date[:-2]+'01'
            elif (data_source=="yearly_summary"):
                initial_date = initial_date[:-5]+'01-01'
                final_date = final_date[:-5]+'01-01'

            initial_datetime = datetime.datetime.strptime(initial_date, '%Y-%m-%d')
            final_datetime = datetime.datetime.strptime(final_date, '%Y-%m-%d')

            num_days = (final_datetime-initial_datetime).days + 1            

            ret_data =  {
                'initial_date': initial_date,
                'final_date': final_date,
                'data_source': data_source,
                'sv_list': sv_list
            }

            query = f"""
                WITH series AS (
                    SELECT station_id, variable_id
                    FROM UNNEST(ARRAY{sv_list}) AS t(station_id int, variable_id int)
                ),
                daily_summ AS(
                    SELECT
                        MIN(day) AS first_day
                        ,MAX(day) AS last_day
                        ,station_id
                        ,variable_id
                        ,100*COUNT(*)/{num_days}::float AS percentage
                    FROM daily_summary
                    WHERE day >= '{initial_date}'
                      AND day <= '{final_date}'
                      AND (station_id, variable_id) IN (SELECT station_id, variable_id FROM series)
                    GROUP BY station_id, variable_id
                )
                SELECT
                    daily_summ.first_day 
                    ,daily_summ.last_day
                    ,series.station_id
                    ,series.variable_id
                    ,COALESCE(daily_summ.percentage, 0)
                FROM series
                LEFT JOIN daily_summ ON daily_summ.station_id = series.station_id AND daily_summ.variable_id = series.variable_id
            """

            result = []

            with connection.cursor() as cursor:
                cursor.execute(query)
                rows = cursor.fetchall()
                for row in rows:
                    new_entry = {
                        'first_date': row[0],
                        'last_date': row[1],
                        'station_id': row[2],
                        'variable_id': row[3],
                        'percentage': round(row[4], 1)
                    }

                    result.append(new_entry)

            return JsonResponse({'data': result}, status=status.HTTP_200_OK)
        except json.JSONDecodeError:
            return Response({'error': 'Invalid JSON format'}, status=status.HTTP_400_BAD_REQUEST)


def DataExportQueryData(initial_datetime, final_datetime, data_source, series, interval):
    DB_NAME=os.getenv('SURFACE_DB_NAME')
    DB_USER=os.getenv('SURFACE_DB_USER')
    DB_PASSWORD=os.getenv('SURFACE_DB_PASSWORD')
    DB_HOST=os.getenv('SURFACE_DB_HOST')
    config = f"dbname={DB_NAME} user={DB_USER} password={DB_PASSWORD} host={DB_HOST}"

    config = settings.SURFACE_CONNECTION_STRING

    series = [(row['station_id'], row['variable_id']) for row in series]

    if (data_source=='raw_data'):
      dfs = []
      ini_day = initial_datetime;
      while (ini_day <= final_datetime):
        fin_day = ini_day + datetime.timedelta(days=1)
        fin_day = fin_day.replace(hour=0, minute=0, second=0, microsecond=0) 

        fin_day = min(fin_day, final_datetime)

        query = f"""
          WITH time_series AS(
            SELECT 
              timestamp AS datetime
            FROM
              GENERATE_SERIES(
                '{ini_day}'::TIMESTAMP
                ,'{fin_day}'::TIMESTAMP
                ,'{interval} SECONDS'
              ) AS timestamp
            WHERE timestamp BETWEEN '{ini_day}' AND '{fin_day}'
          )          
          ,series AS (
              SELECT station_id, variable_id
              FROM UNNEST(ARRAY{series}) AS t(station_id int, variable_id int)
          )
          ,processed_data AS (
            SELECT datetime
                ,station_id
                ,var.id as variable_id
                ,COALESCE(CASE WHEN var.variable_type ilike 'code' THEN data.code ELSE data.measured::varchar END, '-99.9') AS value
            FROM raw_data data
            LEFT JOIN wx_variable var ON data.variable_id = var.id
            WHERE (data.datetime >= '{ini_day}')
              AND ((data.datetime < '{fin_day}') OR (data.datetime='{fin_day}' AND {fin_day > final_datetime}))
              AND (station_id, variable_id) IN (SELECT station_id, variable_id FROM series)
          )
          SELECT 
            ts.datetime AS datetime
            ,series.variable_id AS variable_id
            ,series.station_id AS station_id
            ,COALESCE(data.value, '-99.9') AS value
          FROM time_series ts
          CROSS JOIN series
          LEFT JOIN processed_data AS data
            ON data.datetime = ts.datetime
            AND data.variable_id = series.variable_id
            AND data.station_id = series.station_id;
        """
        with psycopg2.connect(config) as conn:
          with conn.cursor() as cursor:
            logging.info(query)
            cursor.execute(query)
            data = cursor.fetchall()

        dfs.append(pd.DataFrame(data))

        ini_day += datetime.timedelta(days=1)
        ini_day = ini_day.replace(hour=0, minute=0, second=0, microsecond=0)

        if ini_day == final_datetime:
          break

      df = pd.concat(dfs)
      return df
    else:
      if (data_source=='hourly_summary'):
        query = f'''
            WITH time_series AS(
              SELECT 
                timestamp AS datetime
              FROM
                GENERATE_SERIES(
                  DATE_TRUNC('HOUR', '{initial_datetime}'::TIMESTAMP)
                  ,DATE_TRUNC('HOUR', '{final_datetime}'::TIMESTAMP)
                  ,'1 HOUR'
                ) AS timestamp
              WHERE timestamp BETWEEN '{initial_datetime}' AND '{final_datetime}'
            )       
            ,series AS (
                SELECT station_id, variable_id
                FROM UNNEST(ARRAY{series}) AS t(station_id int, variable_id int)
            )
            ,processed_data AS (
              SELECT
                datetime
                ,station_id
                ,var.id as variable_id
                ,COALESCE(CASE 
                  WHEN var.sampling_operation_id in (1,2) THEN data.avg_value::real
                  WHEN var.sampling_operation_id = 3      THEN data.min_value
                  WHEN var.sampling_operation_id = 4      THEN data.max_value
                  WHEN var.sampling_operation_id = 6      THEN data.sum_value
                  ELSE data.sum_value END, '-99.9') as value
              FROM hourly_summary data
              LEFT JOIN wx_variable var ON data.variable_id = var.id
              WHERE data.datetime BETWEEN '{initial_datetime}' AND '{final_datetime}'
                AND (station_id, variable_id) IN (SELECT station_id, variable_id FROM series)
            )
            SELECT 
              ts.datetime AS datetime
              ,series.variable_id AS variable_id
              ,series.station_id AS station_id
              ,COALESCE(data.value, '-99.9') AS value
            FROM time_series ts
            CROSS JOIN series
            LEFT JOIN processed_data AS data
              ON data.datetime = ts.datetime
              AND data.variable_id = series.variable_id
              AND data.station_id = series.station_id;
        '''    
      elif (data_source=='daily_summary'):      
        query = f'''
            WITH time_series AS(
              SELECT 
                timestamp::DATE AS date
              FROM
                GENERATE_SERIES(
                  DATE_TRUNC('DAY', '{initial_datetime}'::TIMESTAMP)
                  ,DATE_TRUNC('DAY', '{final_datetime}'::TIMESTAMP)
                  ,'1 DAY'
                ) AS timestamp
              WHERE timestamp BETWEEN '{initial_datetime}' AND '{final_datetime}'
            )       
            ,series AS (
                SELECT station_id, variable_id
                FROM UNNEST(ARRAY{series}) AS t(station_id int, variable_id int)
            )
            ,processed_data AS (
              SELECT
                day
                ,station_id
                ,var.id as variable_id
                ,COALESCE(CASE 
                  WHEN var.sampling_operation_id in (1,2) THEN data.avg_value::real
                  WHEN var.sampling_operation_id = 3      THEN data.min_value
                  WHEN var.sampling_operation_id = 4      THEN data.max_value
                  WHEN var.sampling_operation_id = 6      THEN data.sum_value
                  ELSE data.sum_value END, '-99.9') as value
              FROM daily_summary data
              LEFT JOIN wx_variable var ON data.variable_id = var.id
              WHERE data.day BETWEEN '{initial_datetime}' AND '{final_datetime}'
                AND (station_id, variable_id) IN (SELECT station_id, variable_id FROM series)
            )
            SELECT 
              ts.date AS date
              ,series.variable_id AS variable_id
              ,series.station_id AS station_id
              ,COALESCE(data.value, '-99.9') AS value
            FROM time_series ts
            CROSS JOIN series
            LEFT JOIN processed_data AS data
              ON data.day = ts.date
              AND data.variable_id = series.variable_id
              AND data.station_id = series.station_id;
        '''
      elif (data_source=='monthly_summary'):
        query = f'''
            WITH time_series AS(
              SELECT 
                timestamp::DATE AS date
              FROM
                GENERATE_SERIES(
                  DATE_TRUNC('MONTH', '{initial_datetime}'::TIMESTAMP)
                  ,DATE_TRUNC('MONTH', '{final_datetime}'::TIMESTAMP)
                  ,'1 MONTH'
                ) AS timestamp
              WHERE timestamp BETWEEN '{initial_datetime}' AND '{final_datetime}'
            )       
            ,series AS (
                SELECT station_id, variable_id
                FROM UNNEST(ARRAY{series}) AS t(station_id int, variable_id int)
            )
            ,processed_data AS (
              SELECT
                date
                ,station_id
                ,var.id as variable_id
                ,COALESCE(CASE 
                  WHEN var.sampling_operation_id in (1,2) THEN data.avg_value::real
                  WHEN var.sampling_operation_id = 3      THEN data.min_value
                  WHEN var.sampling_operation_id = 4      THEN data.max_value
                  WHEN var.sampling_operation_id = 6      THEN data.sum_value
                  ELSE data.sum_value END, '-99.9') as value
              FROM monthly_summary data
              LEFT JOIN wx_variable var ON data.variable_id = var.id
              WHERE data.date BETWEEN '{initial_datetime}' AND '{final_datetime}'
                AND (station_id, variable_id) IN (SELECT station_id, variable_id FROM series)
            )
            SELECT 
              ts.date AS date
              ,series.variable_id AS variable_id
              ,series.station_id AS station_id
              ,COALESCE(data.value, '-99.9') AS value
            FROM time_series ts
            CROSS JOIN series
            LEFT JOIN processed_data AS data
              ON data.date = ts.date
              AND data.variable_id = series.variable_id
              AND data.station_id = series.station_id;        
        '''
      elif (data_source=='yearly_summary'):
        query = f'''
            WITH time_series AS(
              SELECT 
                timestamp::DATE AS date
              FROM
                GENERATE_SERIES(
                  DATE_TRUNC('YEAR', '{initial_datetime}'::TIMESTAMP)
                  ,DATE_TRUNC('YEAR', '{final_datetime}'::TIMESTAMP)
                  ,'1 YEAR'
                ) AS timestamp
              WHERE timestamp BETWEEN '{initial_datetime}' AND '{final_datetime}'
            )       
            ,series AS (
                SELECT station_id, variable_id
                FROM UNNEST(ARRAY{series}) AS t(station_id int, variable_id int)
            )
            ,processed_data AS (
              SELECT
                date
                ,station_id
                ,var.id as variable_id
                ,COALESCE(CASE 
                  WHEN var.sampling_operation_id in (1,2) THEN data.avg_value::real
                  WHEN var.sampling_operation_id = 3      THEN data.min_value
                  WHEN var.sampling_operation_id = 4      THEN data.max_value
                  WHEN var.sampling_operation_id = 6      THEN data.sum_value
                  ELSE data.sum_value END, '-99.9') as value
              FROM yearly_summary data
              LEFT JOIN wx_variable var ON data.variable_id = var.id
              WHERE data.date BETWEEN '{initial_datetime}' AND '{final_datetime}'
                AND (station_id, variable_id) IN (SELECT station_id, variable_id FROM series)
            )
            SELECT 
              ts.date AS date
              ,series.variable_id AS variable_id
              ,series.station_id AS station_id
              ,COALESCE(data.value, '-99.9') AS value
            FROM time_series ts
            CROSS JOIN series
            LEFT JOIN processed_data AS data
              ON data.date = ts.date
              AND data.variable_id = series.variable_id
              AND data.station_id = series.station_id;        
        '''               

      with psycopg2.connect(config) as conn:
        with conn.cursor() as cursor:
          logging.info(query)
          cursor.execute(query)
          data = cursor.fetchall()

      df = pd.DataFrame(data)
    return df


class AppDataExportView(views.APIView):
    permission_classes = (IsAuthenticated,)

    def post(self, request, *args, **kwargs):
        serializer = serializers.DataExportSerializer(data=request.data)
        if serializer.is_valid():
            data_dict = {
                key: [dict(item) for item in value] if key == 'series' else value
                for key, value in serializer.validated_data.items()
            }

            initial_datetime = datetime.datetime.combine(data_dict['initial_date'],  data_dict['initial_time'])
            final_datetime = datetime.datetime.combine(data_dict['final_date'],  data_dict['final_time'])

            df = DataExportQueryData(initial_datetime, final_datetime, data_dict['data_source'], data_dict['series'], data_dict['interval'])

            try:
                file_format = data_dict.get('file_format')            
                if(file_format == 'excel'):
                    output = io.BytesIO()
                    df.to_excel(output, index=False, engine='openpyxl')
                    output.seek(0)

                    return HttpResponse(
                        output,
                        content_type='application/vnd.ms-excel',
                        headers={'Content-Disposition': 'attachment; filename="data.xlsx"'}
                    )
                elif(file_format == 'csv'):
                    output = io.StringIO()
                    df.to_csv(output, index=False)
                    output.seek(0)

                    return HttpResponse(
                        output,
                        content_type='text/csv',
                        headers={'Content-Disposition': 'attachment; filename="data.csv"'}
                    )                

                elif(file_format == 'rinstat'):
                    output = io.StringIO()
                    df.to_csv(output, sep='\t', index=False)
                    output.seek(0)
                    
                    return HttpResponse(
                        output,
                        content_type='text/tab-separated-values',
                        headers={'Content-Disposition': 'attachment; filename="data.tsv"'}
                    )
                else:
                    return HttpResponse('Unsupported file format', status=400)
            except Exception as e:
                return HttpResponse('An error occurred: {}'.format(e), status=500)
        else:
            return HttpResponse(
                json.dumps({'message': 'Validation failed', 'errors': serializer.errors}),
                content_type='application/json',
                status=400
            )


class IntervalViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = Interval.objects.all().order_by('seconds')
    serializer_class = serializers.IntervalSerializer

def get_synop_table_config():
    # List of variables, in order, for synoptic station input form
    variable_symbols = [
        'WINDINDR', 'PRECIND', 'STATIND', 'LOWCLHFt', 'VISBY-km',
        'CLDTOT', 'WNDDIR', 'WNDSPD', 'TEMP', 'TDEWPNT', 'TEMPWB',
        'RH', 'PRESSTN', 'PRESSEA', 'BAR24C', 'PRECIP', 'PREC24H', 'PRECDUR', 'PRSWX',
        'W1', 'W2', 'Nh', 'CL', 'CM', 'CH', 'STSKY',
        'DL', 'DM', 'DH', 'TEMPMAX', 'TEMPMIN', 'N1', 'C1', 'hhFt1',
        'N2', 'C2', 'hhFt2', 'N3', 'C3', 'hhFt3', 'N4', 'C4', 'hhFt4', 'SpPhenom'
    ]
    
    # Get a variable list using the order of variable_ids list
    variable_dict = {variable.symbol: variable for variable in Variable.objects.filter(symbol__in=variable_symbols)}
    variable_list = [variable_dict[variable_symbol] for variable_symbol in variable_symbols]

    nested_headers = [
        [variable.name for variable in variable_list]+['Remarks', 'Observer', 'Action'],
        # [variable.symbol for variable in variable_list]+['Remarks', 'Observer', 'Action'],
        [
            (
                variable.synoptic_code_form
            ) 
            if variable.synoptic_code_form is not None 
            else '' 
            for variable in variable_list
         ]+['', '', ''],
    ]

    col_widths = [
        99, 146, 176, 136, 61, 61, 107, 100, 83,
        171, 154, 117, 175, 163, 180, 129, 129, 181, 112,
        144, 144, 169, 108, 124, 110, 82, 148, 153,
        150, 208, 212, 162, 159, 195, 162, 159, 195,
        162, 159, 195, 162, 159, 195, 145, 64, 65, 49
    ]


    columns = []
    for variable in variable_list:
        if (variable.variable_type=='Numeric' and variable.id not in [0, 4057, 4055, 4058, 4059, 4060, 4061]):
            var_type='numeric'
            numeric_format = '0'
            if variable.scale > 0:
                numeric_format = '0.'+'0'*variable.scale

            new_column = {
                'data': str(variable.id),
                'name': str(variable.symbol),
                'type': var_type,
                'numericFormat': {'pattern': numeric_format},
                'validator': 'numericFieldValidator'
            }
        elif (variable.variable_type=='Numeric' and variable.id in [0]):
            var_type='numeric'
            numeric_format = '0'
            if variable.scale > 0:
                numeric_format = '0.'+'0'*variable.scale

            new_column = {
                'data': str(variable.id),
                'name': str(variable.symbol),
                'type': var_type,
                'numericFormat': {'pattern': numeric_format},
                'validator': 'customPrecipFieldValidator'
            }
        elif (variable.variable_type=='Numeric' and variable.id in [4058, 4059, 4060, 4061]):
            var_type='numeric'
            numeric_format = '0'
            if variable.scale > 0:
                numeric_format = '0.'+'0'*variable.scale

            new_column = {
                'data': str(variable.id),
                'name': str(variable.symbol),
                'type': var_type,
                'numericFormat': {'pattern': numeric_format},
                'validator': 'customCloudFieldValidator'
            }
        elif(variable.variable_type=='Code'):
            var_type='dropdown'
            new_column = {
                'data': str(variable.id),
                'name': str(variable.symbol),
                'type': var_type,
                'codetable': variable.code_table_id,
                'strict': 'true',
                'validator': 'dropdownFieldValidator'
            }   
        elif (variable.variable_type=='Numeric' and variable.id in [4057, 4055]): # the 24hr barometric change column
            var_type='numeric'
            numeric_format = '0'
            if variable.scale > 0:
                numeric_format = '0.'+'0'*variable.scale

            new_column = {
                'data': str(variable.id),
                'name': str(variable.symbol),
                'type': var_type,
                'numericFormat': {'pattern': numeric_format},
                'validator': 'numericFieldValidator',
                'readOnly': 'true',
            }      
        else:
            var_type='text'
            numeric_format=None
            new_column = {
                'data': str(variable.id),
                'name': str(variable.symbol),
                'type': var_type,
                'validator': 'textFieldValidator',
            }

        columns.append(new_column)
 
    columns.append({
        'data': 'remarks',
        'name':'remarks',
        'type': 'text',
        'validator': 'textFieldValidator'
    })
    columns.append({
        'data': 'observer',
        'name':'observer',
        'type': 'text',
        'validator': 'textFieldValidator'
    })
    columns.append({
        'data': 'action',
        'renderer': 'deleteButtonRenderer',
        'readOnly': 'true',
    })   

    row_headers = [
        '00:00','01:00','02:00','03:00','04:00','05:00','06:00','07:00',
        '08:00','09:00','10:00','11:00','12:00','13:00','14:00','15:00',
        '16:00','17:00','18:00','19:00','20:00','21:00','22:00','23:00',
        'SUM', 'AVG', 'MIN', 'MAX', 'STDDEV', 'COUNT'
    ]
    number_of_columns = len(columns)
    number_of_rows = len(row_headers)
    
    # Get wmo code values to use in dropdown for code variables
    wmocodevalue_list = WMOCodeValue.objects.values('value', 'code_table_id')
    wmocodevalue_dict = {}
    for item in wmocodevalue_list:
        code_table_id = item['code_table_id']

        if code_table_id not in wmocodevalue_dict:
            wmocodevalue_dict[code_table_id] = []

        wmocodevalue_dict[code_table_id].append(item['value'])

    context = {
        'col_widths': col_widths,
        'nested_headers': nested_headers,
        'row_headers': row_headers,
        'columns': columns,
        'variable_ids': [variable.id for variable in variable_list],
        'wmocodevalue_dict': wmocodevalue_dict,
        'number_of_columns': number_of_columns,
        'number_of_rows': number_of_rows,
    }
    return context


class SynopView(LoginRequiredMixin, TemplateView):
    template_name = "wx/data/synop.html"

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)

        context['station_list'] = Station.objects.filter(is_synoptic=True).values('id', 'name', 'code')
        context['handsontable_config'] = get_synop_table_config()
        # Get parameters from request or set default values
        station_id = request.GET.get('station_id', 'null')
        date = request.GET.get('date', datetime.date.today().isoformat())
        context['station_id'] = station_id
         # context['date'] = date

        # changing the date so that if reflects that users timezone
        offset = datetime.timedelta(minutes=(settings.TIMEZONE_OFFSET))
        dt_object = datetime.datetime.now() + offset

        context['date'] = dt_object.date()

        return self.render_to_response(context)    


@csrf_exempt
def synop_pressure_calc(request):
    if request.method == 'POST':
        station_id = tuple([request.GET['station_id']])
        data = json.loads(request.body)  # Parse JSON data
        pressure_value = float(data.get('pressure_value')) 
        date_value = data.get('date')

        station = Station.objects.get(pk=station_id[0]) 
        # Invert the station's UTC offset (minutes) to convert its local time to UTC.
        offset = datetime.timedelta(minutes=(-1 * station.utc_offset_minutes))

        # Convert the string to a datetime object:
        dt_object = datetime.datetime.strptime(date_value, "%Y-%m-%d %H:%M")
        dt_object = dt_object + offset

        # Subtract 24 hours:
        dt_24_hours_ago = dt_object - timedelta(days=1)

        # Format the resulting datetime object back into a string:
        formatted_date_string = dt_24_hours_ago.strftime("%Y-%m-%dT%H:%MZ")

        pressure_variable_id = (61,)

        # grab the query output for the Station pressure at sea level
        dataset = get_station_raw_data('variable', pressure_variable_id, None, formatted_date_string, formatted_date_string,
                                           station_id)

        if dataset['results']:
            pressure_data = dataset['results']['Pressure at Sea Level (hPa)']

            # Since there's only one station, get the first (and only) key
            station_name = next(iter(pressure_data))

            value = pressure_data[station_name]['data'][0]['value']  

            # return the absolute value as the pressure difference
            pressure_difference = abs(value - pressure_value) if pressure_value != -99.9 and value != -99.9 else -99.9
        else:
            pressure_difference = 'no data'

        # display the error message
        if dataset['messages']:
            logger.error(f"An error occured whilst retrieving 24hr baromatric change value: {dataset['messages']}")
        
    return JsonResponse({'dataset': pressure_difference}, status=status.HTTP_200_OK)



@csrf_exempt
def synop_precip_calc(request):
    if request.method == 'POST':
        station_id = int(request.GET['station_id'])
        data = json.loads(request.body)  # Parse JSON data
        precip_value = float(data.get('precipitation_value')) 
        precip_24_hr = 0
        date_value = data.get('date')

        station = Station.objects.get(pk=station_id) 
        # Invert the station's UTC offset (minutes) to convert its local time to UTC.
        offset = datetime.timedelta(minutes=(-1 * station.utc_offset_minutes))

        # Convert the string to a datetime object:
        dt_object = datetime.datetime.strptime(date_value, "%Y-%m-%d %H:%M")
        dt_object = dt_object + offset

        # Subtract 24 hours:
        dt_24_hours_ago = dt_object - timedelta(days=1)

        # Format the resulting datetime object back into a string:
        formatted_dt_24_hours_ago = dt_24_hours_ago.strftime("%Y-%m-%dT%H:%MZ")

        # Format the datetime object also
        formatted_dt_object = dt_object.strftime("%Y-%m-%dT%H:%MZ")

        precipitation_variable_id = 0

        sql_string = """
            SELECT measured
            FROM raw_data
            WHERE station_id = %s
            AND variable_id = %s
            AND datetime BETWEEN %s AND %s;
        """

        if sql_string:
            with connection.cursor() as cursor:

                cursor.execute(sql_string, [station_id, precipitation_variable_id, formatted_dt_24_hours_ago, formatted_dt_object])

                rows = cursor.fetchall()
            
                # adding to get the total precipitation in 24 hours
                precip_24_hr = sum(row[0] for row in rows if row[0] != -99.9) + precip_value
        
    return JsonResponse({'dataset': precip_24_hr}, status=status.HTTP_200_OK)


@api_view(['POST'])
def synop_update(request):
    try:
        day = datetime.datetime.strptime(request.GET['date'], '%Y-%m-%d')
        station_id = request.GET['station_id']

        hours_dict = request.data['table']
        now_utc = datetime.datetime.now().astimezone(pytz.UTC)
        now_utc+= datetime.timedelta(hours=settings.PGIA_REPORT_HOURS_AHEAD_TIME)

        station = Station.objects.get(id=station_id)
        datetime_offset = pytz.FixedOffset(station.utc_offset_minutes)

        seconds = 3600

        records_list = []
        for hour, hour_data in hours_dict.items():
            data_datetime = day.replace(hour=int(hour))
            data_datetime = datetime_offset.localize(data_datetime)
            if data_datetime <= now_utc:
                if hour_data:
                    if 'action' in hour_data.keys():
                        hour_data.pop('action')

                    if 'remarks' in hour_data.keys():
                        remarks = hour_data.pop('remarks')
                    else:
                        remarks = None

                    if 'observer' in hour_data.keys():
                        observer = hour_data.pop('observer')
                    else:
                        observer = None

                    for variable_id, measurement in hour_data.items():
                        variable = Variable.objects.get(pk=variable_id)
                        if measurement is None:
                            measurement_value = settings.MISSING_VALUE
                            measurement_code = settings.MISSING_VALUE_CODE
                        else:
                            if (variable.variable_type=='Numeric'):
                                try:
                                    measurement_value = float(measurement)
                                    measurement_code = measurement
                                except Exception:
                                    measurement_value = settings.MISSING_VALUE
                                    measurement_code = settings.MISSING_VALUE_CODE
                            else:
                                measurement_value = settings.MISSING_VALUE
                                measurement_code = measurement
                            
                        records_list.append((
                            station_id, variable_id, seconds, data_datetime, measurement_value, 1, None,
                            None, None, None, None, None, None, None, False, remarks, observer,
                            measurement_code))

        insert_raw_data_synop.insert(
            raw_data_list=records_list,
            date=day,
            station_id=station_id,
            override_data_on_conflict=True,
            utc_offset_minutes=station.utc_offset_minutes
        )

    except Exception as e:
        logger.error(repr(e))
        return HttpResponse(status=status.HTTP_500_INTERNAL_SERVER_ERROR)

    return HttpResponse(status=status.HTTP_200_OK)


def get_synop_data(station, date, utc_offset_minutes=0):
    datetime_offset = pytz.FixedOffset(utc_offset_minutes)
    request_datetime = datetime_offset.localize(date)

    start_datetime = request_datetime
    end_datetime = request_datetime + datetime.timedelta(days=1)

    with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
        with conn.cursor() as cursor:
            query = f"""
                SELECT 
                    (datetime + INTERVAL '{utc_offset_minutes} MINUTES') AT TIME ZONE 'utc',
                    variable_id,
                    CASE WHEN var.variable_type = 'Numeric' THEN measured::VARCHAR
                        ELSE code
                    END AS value,
                    remarks,
                    observer
                FROM raw_data
                JOIN wx_variable var ON raw_data.variable_id=var.id
                WHERE station_id = {station.id}
                    AND datetime >= '{start_datetime}'
                    AND datetime < '{end_datetime}'
                """

            cursor.execute(query)
            data = cursor.fetchall()
    return data


@api_view(['GET'])
def synop_load(request):
    try:
        date = datetime.datetime.strptime(request.GET['date'], '%Y-%m-%d')
        station = Station.objects.get(id=request.GET['station_id'])
    except ValueError as e:
        logger.error(repr(e))
        return HttpResponse(status=status.HTTP_400_BAD_REQUEST)
    except Exception as e:
        logger.error(repr(e))
        return HttpResponse(status=status.HTTP_500_INTERNAL_SERVER_ERROR)
    
    response = get_synop_data(station, date, station.utc_offset_minutes)

    return JsonResponse(response, status=status.HTTP_200_OK, safe=False)


@api_view(['POST'])
def synop_delete(request):
    # Extract data from the request
    request_date_str = request.GET.get('date', None)
    hour = request.GET.get('hour', None)
    station_id = request.GET.get('station_id', None)
    
    hour = int(hour)

    variable_id_list = request.data.get('variable_ids')

    # Validate inputs
    if (None in [request_date_str, hour, station_id, variable_id_list]):
        message = "Invalid request. 'date', 'hour', 'station_id', and 'variable_ids' must be provided."
        return JsonResponse({"message": message}, status=status.HTTP_400_BAD_REQUEST)

    # Validate date format
    try:
        request_date = datetime.datetime.strptime(request_date_str, '%Y-%m-%d')
    except ValueError:
        message = "Invalid date format. The expected date format is 'YYYY-MM-DD'"
        return JsonResponse({"message": message}, status=status.HTTP_400_BAD_REQUEST)
    
    variable_id_list = tuple(variable_id_list)
    station = Station.objects.get(id=station_id)
    datetime_offset = pytz.FixedOffset(station.utc_offset_minutes)
    request_datetime = datetime_offset.localize(request_date.replace(hour=hour))

    queries = {
        "delete_raw_data": f"""
            DELETE FROM raw_data
            WHERE station_id = {station_id}
              AND variable_id IN {variable_id_list}
              AND datetime = '{request_datetime}'
        """,
        "create_daily_summary": f"""
            INSERT INTO wx_dailysummarytask (station_id, date, created_at, updated_at)
            VALUES ({station_id}, '{request_datetime}', now(), now())
            ON CONFLICT DO NOTHING
        """,
        "create_hourly_summary": f"""
            INSERT INTO wx_hourlysummarytask (station_id, datetime, created_at, updated_at)
            VALUES ({station_id}, '{request_datetime}', now(), now())
            ON CONFLICT DO NOTHING
        """,
        "get_last_updated": f"""
            SELECT max(last_data_datetime)
            FROM wx_stationvariable
            WHERE station_id = {station_id}
              AND variable_id IN {variable_id_list}
            ORDER BY 1 DESC
        """,
        "update_last_updated": f"""
            WITH rd AS (
                SELECT station_id, variable_id, measured, code, datetime,
                       RANK() OVER (PARTITION BY station_id, variable_id ORDER BY datetime DESC) AS datetime_rank
                FROM raw_data
                WHERE station_id = {station_id}
                  AND variable_id IN {variable_id_list}
            )
            UPDATE wx_stationvariable sv
            SET last_data_datetime = rd.datetime,
                last_data_value = rd.measured,
                last_data_code = rd.code
            FROM rd
            WHERE sv.station_id = rd.station_id
              AND sv.variable_id = rd.variable_id
              AND rd.datetime_rank = 1
        """
    }

    with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
        with conn.cursor() as cursor:
            cursor.execute(queries["delete_raw_data"])
            # After deleting from raw_data, is necessary to update the daily and hourly summary tables.
            cursor.execute(queries["create_daily_summary"])
            cursor.execute(queries["create_hourly_summary"])
            
            # If suceed in inserting new data, it's necessary to update the 'last data' columns in wx_stationvariable tabl.
            cursor.execute(queries["get_last_updated"])
            
            last_data_datetime_row = cursor.fetchone()
            if last_data_datetime_row and last_data_datetime_row[0] == request_datetime:
                cursor.execute(queries['update_last_updated'])
        conn.commit()

    return Response([], status=status.HTTP_200_OK)


def get_synop_form_config():
    nested_headers = [
        ["Report Indicator", "Date-Time or Time-UTC", "Wind Ind'r", "Station No. or Location Indicator",
            "6-Group Ind.", "7-Group Ind.", "Lowest Cloud height", "Visibility", "Total cloud", "Wind Direction",
            "Wind Speed", "Indicator and sign", "Air Temperature", "Indicator and sign", "Dew Point", 
            "V.P.", "R.H.", "Indicator", "QNH", "Indicator", "QNH",
            "Indicator", "Rainfall Since Last Report", "6-hr periods", "Indicator", "Present Weather",
            { 'label': "Past Weather", 'colspan': 2 }, "Indicator", "Amt. CL/CM", "CL Clouds", "CM Clouds", "CH Clouds",
            "SECTION 3 Indicator", "Indicator", "State of sky", "CL Direction", "CM Direction", "CH Direction",
            "Indicator and sign", "Maximum Temperature", "Indicator and sign", "Minimum Temperature", "Indicator",
            "24-hour Barometric change", "Indicator", "24-hour Rainfall at 00Z, 06Z, 12Z and 18Z",
            "Indicator", "Amt. of layer", "Form of layer", "Height of lowest layer", "Indicator",
            "Amt. of layer", "Form of layer", "Height of next layer", "Indicator", "Amt. of layer",
            "Form of layer", "Height of next layer", "Indicator", "Amt. of layer", "Form of layer",
            "Height of next layer", "Special Phenomena", "REMARKS", "Initails"
        ],
        ["Land Station-no distinction AAXX", "GGggYYGG", "iW", "IIiii", "iR", "iX", "h [In Meters]", "(VV) VV", "N",
            "ddd dd", "(fmfm) f f", "1sn", "T'T' TTT", "2sn", "T'dT'd Td TdTd", "UUU", "",
            "3", "POPOPOPO", "4", "PHPHPHPH PPPP", "6", "RRR", "Tr", "7", "ww", "W1", "W2", "8", "Nh", "CL",
            "CM", "CH", "333", "0", "CS", "DL", "DM", "DH", "1sn", "TXTXTX", "2sn", "TnTnTn", "5j1",
            "P24P24P24", "7", "R24R24R24R24", "8", "NS", "C", "hShS", "8", "NS", "C", "hShS", "8", "NS",
            "C", "hShS", "8", "NS", "C", "hShS", "9SPSPsPsP", "", ""
        ],
    ]

    number_of_columns = len(nested_headers[0])+1 # Adding the colspan

    columns = []
    for i in range(number_of_columns):
        new_column = {
            'data': i,
            'name': str(i),
            'type': 'text',
            'readOnly': 'true',
        }
        columns.append(new_column)

    context = {
        'nested_headers': nested_headers,
        'columns': columns,
        'number_of_columns': number_of_columns,
        'number_of_rows': 24
    }

    return context


class SynopFormView(LoginRequiredMixin, TemplateView):
    template_name = "wx/data/synop_form.html"

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)
        context['station_list'] = Station.objects.filter(is_synoptic=True).values('id', 'name', 'code')
        context['handsontable_config'] = get_synop_form_config()
        
        
        # Get parameters from request or set default values
        station_id = request.GET.get('station_id', 'null')
        date = request.GET.get('date', datetime.date.today().isoformat())
        context['station_id'] = station_id
        context['date'] = date

        return self.render_to_response(context)


def get_synop_pvd_data(station, date):
    datetime_offset = pytz.FixedOffset(station.utc_offset_minutes)
    request_datetime = datetime_offset.localize(date)

    pvd_data = []
    with psycopg2.connect(settings.SURFACE_CONNECTION_STRING) as conn:
        with conn.cursor() as cursor:
            query = f"""
                SELECT
                    (datetime + INTERVAL '{station.utc_offset_minutes} MINUTES') AT TIME ZONE 'utc',
                    variable_id,
                    CASE WHEN var.variable_type = 'Numeric' THEN measured::VARCHAR
                        ELSE code
                    END AS value
                FROM raw_data
                INNER JOIN wx_variable var ON raw_data.variable_id=var.id
                WHERE datetime >='{request_datetime-datetime.timedelta(days=1)}'
                  AND datetime < '{request_datetime}'
                  AND station_id={station.id}
                  AND var.symbol IN ('PRECSLR', 'PRECDUR', 'PRESSTN')
            """
            
            cursor.execute(query)
            pvd_data = cursor.fetchall()

    return pvd_data


@api_view(['GET'])
def synop_load_form(request):
    # Functions that are used to format the data
    def alphaCalc(air_temp: float):
        return (17.27 * air_temp) / (air_temp + 237.3)
    
    def vaporPressureCalc(air_temp: float, air_temp_wb: float, atm_pressure: float):
        E_w = 6.108 * math.exp(alphaCalc(air_temp_wb))
        VP = E_w - (0.00066 * (1 + 0.00115 * air_temp_wb) * (air_temp - air_temp_wb) * atm_pressure)
        return VP    

    def relativeHumidityCalc(air_temp: float, vapor_pressure: float):
        E_s = 6.108 * math.exp(alphaCalc(air_temp))
        RH = (vapor_pressure / E_s) * 100
        return RH

    def dewPointCalc(vapor_pressure: float):
        DP = (237.3*vapor_pressure)/(1-vapor_pressure)
        return DP

    def airTempCalc(value: float):
        return None if value is None else abs(round(10*value))

    def atmPressureCalc(atm_pressure: float):
        return None if atm_pressure is None else f"{round(atm_pressure*10) % 10000:04}"

    def windSpeedToCode(wind_speed_val: float):
        # It was requested by Akeisha and Dwayne to just use last two digits
        if wind_speed_val is None or str(wind_speed_val)==str(settings.MISSING_VALUE):
            return '/'
        return str(round(wind_speed_val%100)).zfill(2)
            
        # Using WMO code 1200
        if wind_speed_val is None or str(wind_speed_val)==str(settings.MISSING_VALUE) :
            wind_speed_code = '/'
        elif 0 <= wind_speed_val < 90:
            wind_speed_code = str(math.floor(wind_speed_val/10))
        elif wind_speed_val >= 90:
            wind_speed_code = str(9)
        else:
            wind_speed_code = '/'

        return wind_speed_code

    def windDirToCode(wind_dir: float):
        # It was requested by Akeisha and Dwayne to just divide by 10
        if wind_dir is None or str(wind_dir)==str(settings.MISSING_VALUE) : 
            return None
        return str(round((wind_dir%360)/10)).zfill(2)
    
        # Using WMO code 0877
        if wind_dir is None or str(wind_dir)==str(settings.MISSING_VALUE) : 
            return None
        elif 0 <= wind_dir<=360: 
            wind_dir_code = math.floor(((wind_dir-5)%360)/10)+1
            print(wind_dir_code)
        else:
            wind_dir_code = 99

        wind_dir_code = str(wind_dir_code).zfill(2)
        return wind_dir_code

    def lowestCloutHightToCode(lowest_ch: float):
        if lowest_ch is None or str(lowest_ch)==str(settings.MISSING_VALUE) :
            return '/'
        elif 0 <= lowest_ch < 50:
            return 0
        elif 50 <= lowest_ch < 100:
            return 1
        elif 100 <= lowest_ch < 200:
            return 2
        elif 200 <= lowest_ch < 300:
            return 3
        elif 300 <= lowest_ch < 600:
            return 4
        elif 600 <= lowest_ch < 1000:
            return 5
        elif 1000 <= lowest_ch < 1500:
            return 6
        elif 1500 <= lowest_ch < 2000:
            return 7
        elif 2000 <= lowest_ch < 2500:
            return 8
        elif 2500 <= lowest_ch:
            return 9

    def reinfallToCode(rainfall:float):
        # Rainfall in mm.
        if rainfall is None or rainfall < 0:
            return '///'
        elif rainfall==0:
            return '000'
        elif rainfall < 1:
            return f'99{round(rainfall*10)}'
        elif rainfall < 989:
            return f'{round(rainfall):03}'
        elif rainfall >= 989:
            return '989'
        else:
            return '///'

    def reinfall24hToCode(rainfall:float):
        # Rainfall in mm.
        if rainfall is None or rainfall < 0:
            return None

        rainfall *= 10
        if 0 < rainfall < 1:
            return 9999 # Trace
        
        rainfall = round(rainfall)
        if rainfall < 9998:
            return f'{rainfall:04}'
        else:
            return '9998'
        
    def precdurCodeToValue(code: str):
        # This dictionary must match WMO vlues for code 4019
        code_table = {
            '1': 6,
            '2': 12,
            '3': 18,
            '4': 24,
            '5': 1,
            '6': 2,
            '7': 3,
            '8': 9,
            '9': 15
        }
        if code not in code_table.keys():
            return None
        return code_table[code]
        
    def reinfallLast24h(curr_datetime:datetime, rainfall_data:list, rainfall_dur_data:list ):
        # If there is precipitation was not measured at the exact datetime we can not infere what was the last 24h
        if (len([row for row in rainfall_data if row[0] == curr_datetime])!=1):
            return None

        last24h_datetime = curr_datetime-datetime.timedelta(hours=24)
        
        prec24h_data = [row for row in rainfall_data if (last24h_datetime < row[0] <= curr_datetime)]
        prec24h_data = sorted(prec24h_data, key=lambda x: x[0], reverse=True)

        prec_sum = 0; precdur_sum = 0
        for prec_row in prec24h_data:
            prec_value = prec_row[2]

            if prec_value in [str(settings.MISSING_VALUE), settings.MISSING_VALUE_CODE]:
                prec_value = None
            
            if prec_value is not None:
                prec_value = float(prec_value)
                precdur_code = next((precdur_row[2] for precdur_row in rainfall_dur_data if precdur_row[0] == prec_row[0]),None)

                # If there is precipitation and no duration then we can not infere what was the last 24h
                if precdur_code is None or precdur_code==settings.MISSING_VALUE_CODE:
                    return None
                
                precdur_sum+=precdurCodeToValue(precdur_code)
                prec_sum+=prec_value
                if precdur_sum==24:
                    return reinfall24hToCode(prec_sum)
                
                # If duration exceeds 24h we can not infere what was the last 24h
                elif precdur_sum>24:
                    return None
            
        # If duration is below 24h we can not infere what was the last 24h
        return None

    try:
        date = datetime.datetime.strptime(request.GET['date'], '%Y-%m-%d')
        station = Station.objects.get(id=request.GET['station_id'])
    except ValueError as e:
        logger.error(repr(e))
        return HttpResponse(status=status.HTTP_400_BAD_REQUEST)
    except Exception as e:
        logger.error(repr(e))
        return HttpResponse(status=status.HTTP_500_INTERNAL_SERVER_ERROR)

    # Current Day Data
    data =  get_synop_data(station, date, utc_offset_minutes=0)

    # Previous Day Data
    pvd_data = get_synop_pvd_data(station, date)

    variables = Variable.objects.all()

    # Precipitation Measurements
    rainfall_data = [row for row in pvd_data + data if row[1] == variables.get(symbol='PRECSLR').id and str(row[2]) != str(settings.MISSING_VALUE)]
    # Precipitation Duration Measurements
    rainfall_dur_data = [row for row in pvd_data + data if row[1] == variables.get(symbol='PRECDUR').id and str(row[2]) != str(settings.MISSING_VALUE)]

    # This is a table reference that is usedd to identify what is the type of the data.
    # Const is used for constant values.
    # Var is used for general variable.
    # Text is used for text values.
    # SpVar is used for special variable that need some formating.
    # Func is used for functions like Date-Hour, Vapor Pressure, etc.
    # 1sn, 2sn and 5j1 are used for signals, usualy following some variable value.
    reference = [
        {'type': 'Const', 'ref': station.synoptic_type}, {'type': 'Func', 'ref': 'DateHour'},
        {'type': 'Var', 'ref': 'WINDINDR'}, {'type': 'Const', 'ref': station.synoptic_code},
        {'type': 'Var', 'ref': 'PRECIND'}, {'type': 'Var', 'ref': 'STATIND'},
        {'type': 'SpVar', 'ref': 'LOWCLH'}, {'type': 'Var', 'ref': 'VISBY'}, {'type': 'Var', 'ref': 'CLDTOT'},
        {'type': 'SpVar', 'ref': 'WNDDIR'}, {'type': 'SpVar', 'ref': 'WNDSPD'},
        {'type': '1sn', 'ref': 'TEMP'}, {'type': 'SpVar', 'ref': 'TEMP'},
        {'type': '2sn', 'ref': 'TDEWPNT'},
        {'type': 'Func', 'ref': 'DP'}, {'type': 'Func', 'ref': 'VP'}, {'type': 'Func', 'ref': 'RH'},
        {'type': 'Const', 'ref': 3},
        {'type': 'SpVar', 'ref': 'PRESSTN'},
        {'type': 'Const', 'ref': 4},
        {'type': 'SpVar', 'ref': 'PRESSEA'},
        {'type': 'Const', 'ref': 6},
        {'type': 'SpVar', 'ref': 'PRECSLR'}, {'type': 'Var', 'ref': 'PRECDUR'},
        {'type': 'Const', 'ref': 7},
        {'type': 'Var', 'ref': 'PRSWX'}, {'type': 'Var', 'ref': 'W1'}, {'type': 'Var', 'ref': 'W2'},
        {'type': 'Const', 'ref': 8}, 
        {'type': 'Var', 'ref': 'Nh'},
        {'type': 'Var', 'ref': 'CL'}, {'type': 'Var', 'ref': 'CM'}, {'type': 'Var', 'ref': 'CH'},
        {'type': 'Const', 'ref': 333},  
        {'type': 'Const', 'ref': 0},
        {'type': 'Var', 'ref': 'STSKY'},
        {'type': 'Var', 'ref': 'DL'}, {'type': 'Var', 'ref': 'DM'}, {'type': 'Var', 'ref': 'DH'},
        {'type': '1sn', 'ref': 'TEMPMAX'}, {'type': 'SpVar', 'ref': 'TEMPMAX'},
        {'type': '2sn', 'ref': 'TEMPMIN'}, {'type': 'SpVar', 'ref': 'TEMPMIN'},
        {'type': '5j1', 'ref': None}, {'type': 'Func', 'ref': 'BarometricChange'},
        {'type': 'Const', 'ref': 7},
        # {'type': 'Func', 'ref': '24hRainfall'},
        {'type': 'SpVar', 'ref': 'PREC24H'},
        {'type': 'Const', 'ref': 8},
        {'type': 'Var', 'ref': 'N1'}, {'type': 'Var', 'ref': 'C1'}, {'type': 'Var', 'ref': 'hh1'},
        {'type': 'Const', 'ref': 8},
        {'type': 'Var', 'ref': 'N2'}, {'type': 'Var', 'ref': 'C2'}, {'type': 'Var', 'ref': 'hh2'},
        {'type': 'Const', 'ref': 8},
        {'type': 'Var', 'ref': 'N3'}, {'type': 'Var', 'ref': 'C3'},{'type': 'Var', 'ref': 'hh3'},
        {'type': 'Const', 'ref': 8},
        {'type': 'Var', 'ref': 'N4'}, {'type': 'Var', 'ref': 'C4'}, {'type': 'Var', 'ref': 'hh4'},
        {'type': 'Var', 'ref': 'SpPhenom'}, {'type': 'Text', 'ref': 'remarks'}, {'type': 'Text', 'ref': 'observer'},
    ]

    number_of_columns = len(reference)
    number_of_rows = 24

    hotData = []
    for i in range(number_of_rows):
        datetime_row = date+datetime.timedelta(hours=i)
        data_row = [row for row in data if row[0] == datetime_row]
        pvd_data_row = [row for row in pvd_data if row[0] == datetime_row-datetime.timedelta(days=1)]
        dayhour = f"{date.day:02}{i:02}"

        remarks, observer = (data_row[0][3], data_row[0][4]) if data_row else (None, None)

        air_temp = next((float(row[2]) for row in data_row if row[1] == variables.get(symbol='TEMP').id), None)
        air_temp_wb = next((float(row[2]) for row in data_row if row[1] == variables.get(symbol='TEMPWB').id), None)
        atm_pressure = next((float(row[2]) for row in data_row if row[1] == variables.get(symbol='PRESSTN').id), None)
        dew_point = next((float(row[2]) for row in data_row if row[1] == variables.get(symbol='TDEWPNT').id and str(row[2]) != str(settings.MISSING_VALUE)), None)
        pvd_atm_pressure = next((float(row[2]) for row in pvd_data_row if row[1] == variables.get(symbol='PRESSTN').id), None)
        relative_humidity = next((float(row[2]) for row in data_row if row[1] == variables.get(symbol='RH').id and str(row[2]) != str(settings.MISSING_VALUE)), None)


        # time solts to loop through to populate the 24hr brometric change column
        time_slots = [' 00:00', ' 01:00', ' 02:00', ' 03:00', ' 04:00', ' 05:00', ' 06:00', 
                        ' 07:00', ' 08:00', ' 09:00', ' 10:00', ' 11:00', ' 12:00', ' 13:00', 
                        ' 14:00', ' 15:00', ' 16:00', ' 17:00', ' 18:00', ' 19:00', ' 20:00', 
                        ' 21:00', ' 22:00', ' 23:00']
        
        # calculate barometric change
        try:
            # current time slot will be in the form year-month-day hour:minute
            current_time_slot = request.GET['date'] + time_slots[i]

            # Invert the station's UTC offset (minutes) to convert its local time to UTC.
            offset = datetime.timedelta(minutes=(-1 * station.utc_offset_minutes))

            dt_object = datetime.datetime.strptime(current_time_slot, "%Y-%m-%d %H:%M")
            dt_object = dt_object + offset

            # Format the resulting datetime object back into a string:
            formatted_date_string = dt_object.strftime("%Y-%m-%dT%H:%MZ")

            dataset = get_station_raw_data('variable', (4057,), None, formatted_date_string, formatted_date_string,
                                    (int(request.GET['station_id']),))

            if dataset['results']:
                pressure_data = dataset['results']['24-Hour Barometric Change']

                # Since there's only one station, get the first (and only) key
                station_name = next(iter(pressure_data))

                value = pressure_data[station_name]['data'][0]['value']  

                if value == -99.9:
                    barometric_change_24h = None
                else:
                    barometric_change_24h = value
            else:
                barometric_change_24h = None

        except Exception as e:
            logger.error(f"an error occured whilst calculating baraometric change: {e}")
            barometric_change_24h = None



        vars = [air_temp, air_temp_wb, atm_pressure]
        if all(vars) and settings.MISSING_VALUE not in vars:
            vapor_pressure = vaporPressureCalc(air_temp, air_temp_wb, atm_pressure)
        else:
            vapor_pressure = None

        if relative_humidity is None and vapor_pressure is not None:
            relative_humidity = relativeHumidityCalc(air_temp, vapor_pressure)

        if dew_point is None and vapor_pressure is not None:
            dew_point = dewPointCalc(vapor_pressure)

        hotRow = []
        for j in range(number_of_columns):
            column_type=reference[j]['type']
            if column_type=='Const':
                value = reference[j]['ref']
            elif column_type=='1sn':
                value=None
                if data_row:
                    variable = variables.get(symbol=reference[j]['ref'])
                    value = next((float(row[2]) for row in data_row if row[1] == variable.id), None)
                    if str(value) == str(settings.MISSING_VALUE):
                        value = None
                    
                    if value is not None:
                       value = '10' if value >= 0 else '11'
            elif column_type=='2sn':
                value=None
                if data_row:
                    variable = variables.get(symbol=reference[j]['ref'])
                    value = next((float(row[2]) for row in data_row if row[1] == variable.id), None)
                    if str(value) == str(settings.MISSING_VALUE):
                        value = None
                    
                    if value is not None:
                       value = '20' if value >= 0 else '21'
                    elif variable.id == 19 and relative_humidity is not None:
                        value = '29'
            elif column_type=='5j1':
                value = None
                if data_row:
                    if barometric_change_24h is not None:
                        value = '58' if barometric_change_24h >= 0 else '59'    
            elif column_type=='Var':
                value=None
                if data_row:
                    variable = variables.get(symbol=reference[j]['ref'])
                    value = next((row[2] for row in data_row if row[1] == variable.id), None)
            elif column_type=='SpVar':
                value=None
                if data_row:
                    variable =  variables.get(symbol=reference[j]['ref'])
                    value = next((row[2] for row in data_row if row[1] == variable.id), None)
                    
                    if value in [str(settings.MISSING_VALUE), settings.MISSING_VALUE_CODE]:
                        value = None
                    
                    if value is not None:
                        value = float(value)

                    if variable.symbol in ['TEMP', 'TEMPMIN', 'TEMPMAX', 'TDEWPNT']:
                        value = airTempCalc(value)
                    elif variable.symbol in ['PRESSTN', 'PRESSEA']:
                        value = atmPressureCalc(value)
                    elif variable.symbol=='WNDDIR':
                        value = windDirToCode(value)
                    elif variable.symbol=='WNDSPD':
                        value = windSpeedToCode(value)
                    elif variable.symbol=='PRECSLR':
                        value = reinfallToCode(value)
                    elif variable.symbol=='PREC24H':
                        value = reinfall24hToCode(value)
                    elif variable.symbol=='LOWCLH':
                        value = lowestCloutHightToCode(value)
            elif column_type=='Func':
                if reference[j]['ref']=='DateHour':
                    value=dayhour
                elif reference[j]['ref']=='VP':   
                    value = round(vapor_pressure, 1) if vapor_pressure is not None else None            
                elif reference[j]['ref']=='RH':
                    value = round(relative_humidity) if relative_humidity is not None else None
                elif reference[j]['ref']=='DP':
                    value = airTempCalc(dew_point)
                elif reference[j]['ref']=='BarometricChange':
                    value =  f"{abs(barometric_change_24h):04}" if barometric_change_24h is not None else None
                # elif reference[j]['ref']=='24hRainfall':
                #     value = reinfallLast24h(datetime_row, rainfall_data, rainfall_dur_data) if i in [0,6,12,18] else None
                else:
                    value = 'Func'    
            elif column_type=='Text':
                value = {'remarks': remarks, 'observer': observer}.get(reference[j]['ref'])
            else:
                value='??'
            
            if value in [str(settings.MISSING_VALUE), settings.MISSING_VALUE_CODE]:
                value = None
                
            hotRow.append(value)
        hotData.append(hotRow)
    
    response = {}
    response['hotData'] = hotData
    return JsonResponse(response, status=status.HTTP_200_OK, safe=False)

def get_monthly_form_config():
    # List of variables, in order, for synoptic station input form
    variable_symbols = {
        'PRECIP': {'min': 'null', 'max': 'null'},
        'TEMPMAX': {'min': -100, 'max': 500},
        'TEMPMIN': {'min': -100, 'max': 500},
        'TEMPAVG': {'min': -100, 'max': 500},
        'WNDMIL': {'min': 'null', 'max': 'null'},
        'WINDRUN': {'min': 'null', 'max': 'null'},
        'SUNSHNHR': {'min': 0, 'max': 1440},
        'EVAPINI': {'min': 'null', 'max': 'null'},
        'EVAPRES': {'min': 'null', 'max': 'null'},
        'EVAPPAN': {'min': 'null', 'max': 'null'},
        'TEMP': {'min': 'null', 'max': 'null'},
        'TEMPWB': {'min': 'null', 'max': 'null'},
        'TSOIL1': {'min': 'null', 'max': 'null'},
        'TSOIL4': {'min': 'null', 'max': 'null'},
        'DYTHND': {'min': 'null', 'max': 'null'},
        'DYFOG': {'min': 'null', 'max': 'null'},
        'DYHAIL': {'min': 'null', 'max': 'null'},
        'DYGAIL': {'min': 'null', 'max': 'null'},
        'TOTRAD': {'min': 'null', 'max': 'null'},
        'RH@TMAX': {'min': 'null', 'max': 'null'},
        'RHMAX': {'min': 0, 'max': 100},
        'RHMIN': {'min': 0, 'max': 100},
    }
    
    # Get a variable list using the order of variable_ids list
    variable_dict = {variable.symbol: variable for variable in Variable.objects.filter(symbol__in=variable_symbols.keys())}
    variable_list = [variable_dict[variable_symbol] for variable_symbol in variable_symbols.keys()]

    col_widths = [80]*len(variable_list)

    columns = [
        {
            'data': str(variable.id),
            'name': str(variable.symbol),
            'type': 'numeric',
            'numericFormat': {'pattern': '0.0'},
            'validator': 'fieldValidator'
        } for variable in variable_list
    ]

    row_headers = [str(i+1) for i in range(31)]+['SUM', 'AVG', 'MIN', 'MAX', 'STDDEV', 'COUNT']
    number_of_columns = len(columns)
    number_of_rows = len(row_headers)
    
    context = {
        'col_widths': col_widths,
        'col_headers': list(variable_symbols.keys()),
        'row_headers': row_headers,
        'columns': columns,
        'variable_ids': [variable.id for variable in variable_list],
        'number_of_columns': number_of_columns,
        'number_of_rows': number_of_rows,
        'limits': variable_symbols, 
    }
    return context


class MonthlyFormView(LoginRequiredMixin, TemplateView):
    template_name = "wx/data/monthly_form.html"

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)
        context['station_list'] = Station.objects.filter(is_automatic=False, is_active=True).values('id', 'name', 'code')
        context['handsontable_config'] = get_monthly_form_config()
        
        # Get parameters from request or set default values
        context['station_id'] = request.GET.get('station_id', 'null')
        context['date'] = request.GET.get('date', datetime.date.today().strftime('%Y-%m'))

        return self.render_to_response(context)


# wis2box dashboard page
class WIS2DashboardView(LoginRequiredMixin, TemplateView):
    template_name = "wx/wis2dashboard/wis2dashboard.html"

    def get(self, request, *args, **kwargs):
        context = self.get_context_data(**kwargs)

        return self.render_to_response(context) 


# to grap data for the wis2 dashboard
def wis2dashboard_records_list(request):
    try:
        search_criteria = request.GET.get('search_criteria', '').strip().lower()
        
        if search_criteria == 'all':
            queryset = Wis2BoxPublish.objects.select_related("station")
        elif search_criteria == 'publishing':
            queryset = Wis2BoxPublish.objects.filter(publishing=True).select_related("station")
        elif search_criteria == 'publish_status':
            queryset = Wis2BoxPublish.objects.filter(publishing=True).select_related("station")
        elif search_criteria == 'not publishing':
            queryset = Wis2BoxPublish.objects.filter(publishing=False).select_related("station")
        elif search_criteria == 'trans pub':
            queryset = Wis2BoxPublish.objects.filter(publishing=True, hybrid=True).select_related("station")
        elif search_criteria == 'trans nonpub':
            queryset = Wis2BoxPublish.objects.filter(publishing=False, hybrid=True).select_related("station")
        else:
            queryset = Wis2BoxPublish.objects.select_related("station")
        
        if not queryset.exists():
            logger.info("No records found!")
            return JsonResponse({"error": "No records found"}, status=204)

        records = list(queryset.values(
            "id", 
            "publishing", 
            "station__name", 
            "station__wigos", 
            "station__is_automatic", 
            "station__is_synoptic", 
            "publish_success", 
            "publish_fail",
            "hybrid",
            "add_gts",
            "hybrid_station__name"
        ))

        # calculate the total success and fails to create the graph
        publish_success_count = 0
        publish_fail_count = 0

        for record in records:
            if not record['station__wigos']:
                record['station__wigos'] = "WIGOS ID NOT FOUND"

            station_status = []
            # getting the publishing status
            if record['publishing']:
                station_status.append("Publishing")

                # hybrid status
                if record['hybrid']:
                    station_status.append("Hybrid")

                # gts status
                if record['add_gts']:
                    station_status.append("GTS")

                # getting the automatic/manual status
                if record['station__is_automatic']:
                    station_status.append("Automatic")
                else:
                    station_status.append("Manual")

                # synoptic status
                if record['station__is_synoptic']:
                    station_status.append("Synoptic")
                    
            else:
                station_status.append("Not Publishing")

                # hybrid status
                if record['hybrid']:
                    station_status.append("Hybrid")

                # gts status
                if record['add_gts']:
                    station_status.append("GTS")

                # getting the automatic/manual status
                if record['station__is_automatic']:
                    station_status.append("Automatic")
                else:
                    station_status.append("Manual")

                # getting the synoptic status
                if record['station__is_synoptic']:
                    station_status.append("Synoptic")

            # adding the Status to the record object
            record['status'] = station_status

            publish_success_count += record['publish_success']
            publish_fail_count += record['publish_fail']

        if search_criteria == 'publish_status':
            return JsonResponse({"items": records, "publish_success": publish_success_count, "publish_fail": publish_fail_count}, encoder=DjangoJSONEncoder)
        
        return JsonResponse({"items": records}, encoder=DjangoJSONEncoder)

    except Exception as e:
        logger.error(f"An error occured: {e}")
        return JsonResponse({"error": str(e)}, status=500)
    

# to fetch publishig logs information
def publishingLogs(request, pk):
    if request.method != "GET":
        return HttpResponseNotAllowed(["GET"])  # Only allow GET requests

    logs = Wis2BoxPublishLogs.objects.filter(publish_station__id=pk).values(
        "id", "created_at", "last_modified", "publish_station", 
        "success_log", "log", "wis2message_exist", "wis2message"
    )

    # getting station metadata
    station_metadata = Wis2BoxPublish.objects.filter(id=pk).values("station__name", "station__wigos", "publish_success", "publish_fail", "hybrid", "hybrid_station__name")
    return JsonResponse({"logs":list(logs), "station_metadata":list(station_metadata), "timezone_offset":settings.TIMEZONE_OFFSET}, safe=False)  # Convert QuerySet to list


def downloadWis2Logs(request, pk):
    """
    Downloads log files associated with a specific publish station (identified by pk) as a ZIP file.
    """
    logs = Wis2BoxPublishLogs.objects.filter(publish_station__id=pk)
    
    if not logs.exists():
        return HttpResponse("No logs found", status=404)
    
    temp_dir = tempfile.mkdtemp()
    zip_filename = os.path.join(temp_dir, f"logs_{pk}.zip")
    
    with zipfile.ZipFile(zip_filename, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for log_entry in logs:
            # Format the timestamp for uniqueness and readability
            timestamp = localtime(log_entry.created_at).strftime("%Y-%m-%d_%H-%M-%S")
            file_name = f"{timestamp}-{log_entry.id}-logfile.txt"
            file_path = os.path.join(temp_dir, file_name)
            
            # Write log content to a temporary file
            with open(file_path, "w", encoding="utf-8") as log_file:
                log_file.write(log_entry.log)
            
            # Add the file to the ZIP archive
            zipf.write(file_path, arcname=file_name)
    
    # Read the ZIP file and prepare it for download
    with open(zip_filename, "rb") as zip_file:
        response = HttpResponse(zip_file.read(), content_type="application/zip")
        response["Content-Disposition"] = f'attachment; filename="logs_{pk}.zip"'
    
    # Cleanup temporary files and directory
    for file in os.listdir(temp_dir):
        os.remove(os.path.join(temp_dir, file))
    os.rmdir(temp_dir)
    
    return response


def downloadWis2Message(request, pk):
    """
    Downloads WIS2 messages associated with a specific publish station (identified by pk) as a ZIP file.
    """
    messages = Wis2BoxPublishLogs.objects.filter(publish_station__id=pk, wis2message_exist=True)
    
    if not messages.exists():
        return HttpResponse("No logs found", status=404)
    
    temp_dir = tempfile.mkdtemp()
    zip_filename = os.path.join(temp_dir, f"messages_{pk}.zip")
    
    with zipfile.ZipFile(zip_filename, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for message in messages:
            # Format the timestamp for uniqueness and readability
            timestamp = localtime(message.created_at).strftime("%Y-%m-%d_%H-%M-%S")
            file_name = f"{timestamp}-{message.id}-messagefile.csv"
            file_path = os.path.join(temp_dir, file_name)
            
            # Write message content to a temporary file
            with open(file_path, "w", encoding="utf-8") as msg_file:
                msg_file.write(message.wis2message)
            
            # Add the file to the ZIP archive
            zipf.write(file_path, arcname=file_name)
    
    # Read the ZIP file and prepare it for download
    with open(zip_filename, "rb") as zip_file:
        response = HttpResponse(zip_file.read(), content_type="application/zip")
        response["Content-Disposition"] = f'attachment; filename="messages_{pk}.zip"'
    
    # Cleanup temporary files and directory
    for file in os.listdir(temp_dir):
        os.remove(os.path.join(temp_dir, file))
    os.rmdir(temp_dir)
    
    return response

# to load the form to update local wis2 credential
class LocalWisCredentialsUpdateView(generics.RetrieveUpdateAPIView):
    queryset = LocalWisCredentials.objects.all()
    serializer_class = serializers.LocalWisCredentialsSerializer
    permission_classes = [permissions.IsAdminUser]  # Restrict access to admins only

    def get_object(self):
        try:
            return LocalWisCredentials.load()  # Ensures only one instance is updated
        except Exception as e:
            logger.error(f'An error occurred while fetching LocalWisCredentials: {e}')
            raise


# to load the form to update regional wis2 credential
class RegionalWisCredentialsUpdateView(generics.RetrieveUpdateAPIView):
    queryset = RegionalWisCredentials.objects.all()
    serializer_class = serializers.RegionalWisCredentialsSerializer
    permission_classes = [permissions.IsAdminUser]  # Restrict access to admins only

    def get_object(self):
        try:
            return RegionalWisCredentials.load()  # Ensures only one instance is updated
        except Exception as e:
            logger.error(f'An error occurred while fetching RegionalWisCredentials: {e}')
            raise


# to load the form to update the stations publishing settings
class configWis2StationUpdateView(generics.RetrieveUpdateAPIView):
    queryset = Wis2BoxPublish.objects.all()
    serializer_class = serializers.Wis2BoxPublishSerializer
    permission_classes = [permissions.IsAdminUser]  # Restrict access to admins only

    def get_object(self):
        station_id = self.kwargs.get("pk")  # Get ID from URL
        try:
            return Wis2BoxPublish.objects.get(id=station_id)  # Fetch entry by ID
        except Exception as e:
            logger.error(f'An error occurred while fetching Wis2BoxPublish stations data: {e}')
            raise


# shows all stations which are currently set to wis2 publishing
class Wis2BoxPublishListView(views.APIView):
    def get(self, request):
        # Query all the Wis2BoxPublish objects where publishing is True
        queryset = Wis2BoxPublish.objects.filter(publishing=True)
        
        # Serialize the queryset
        serializer = serializers.Wis2BoxPublishSerializerReadPublishing(queryset, many=True)
        
        # Return the serialized data as a response
        return Response(serializer.data, status=status.HTTP_200_OK)


class publishingOffsetViewSet(viewsets.ModelViewSet):
    permission_classes = (IsAuthenticated,)
    queryset = Wis2PublishOffset.objects.all()
        

    def get_serializer_class(self):
        return serializers.Wis2PublishOffsetSerializerRead


@csrf_exempt
def push_to_wis2box(request):
    if request.method == "POST":
        try:
            data = json.loads(request.body)
            station_id = int(data.get("stationId"))

            if not station_id:
                return JsonResponse({}, status=400)

            # attempt station push to wis2box
            tasks.wis2publish_task_now(station_id)

            return JsonResponse({}, status=200)
        except Exception as e:
            return JsonResponse({e}, status=500)

    return JsonResponse({}, status=405)  # Method Not Allowed