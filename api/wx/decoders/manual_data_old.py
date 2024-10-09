import calendar
import datetime
import logging
import time

import pandas as pd
import pytz
from celery import shared_task
from django.core.exceptions import ObjectDoesNotExist, MultipleObjectsReturned
from django.db.models import Value
from django.db.models.functions import Concat

from tempestas_api import settings
from wx.decoders.insert_raw_data import insert
from wx.decoders.insert_hf_data import insert as insert_hf
from wx.models import Station

logger = logging.getLogger('surface.manual_data')
db_logger = logging.getLogger('db')

column_names = [
    'day',
    'rainfall',
    'temp_max',
    'temp_min',
    'wind_cup_counter',
    'wind_24h_thrown_back',
    'sunshine',
    'evaporation_initial',
    'evaporation_reset',
    'evaporation_24h_thrown_back',
    'dry_bulb',
    'wet_bulb',
    'soil_temp_1_foot',
    'soil_temp_4_foot',
    'weather_ts',
    'weather_fog',
    'total_rad'
]

# verificar
variable_dict = {
    'rainfall': 0,
    'temp_min': 14,
    'temp_max': 16,
    'wind_cup_counter': 102,
    'wind_24h_thrown_back': 103,
    'sunshine': 77,
    # 'evaporation_initial',
    # 'evaporation_reset',
    'evaporation_24h_thrown_back': 40,
    'dry_bulb': 10,
    'wet_bulb': 18,
    'soil_temp_1_foot': 21,
    'soil_temp_4_foot': 23,
    'weather_ts': 104,
    'weather_fog': 106,
    'total_rad': 70
}


def parse_date(month_datetime, day, utc_offset):
    datetime_offset = pytz.FixedOffset(utc_offset)
    date = month_datetime.replace(day=day)
    return datetime_offset.localize(date)

def is_integer_num(num):
    if isinstance(num, int):
        return True
    if isinstance(num, float):
        return num.is_integer()
    return False

def parse_line(line, station_id, month_datetime, utc_offset):
    """Parse a manual data row"""

    records_list = []
    day = line['day']
    if is_integer_num(day):
        day = int(day)
    parsed_date = parse_date(month_datetime, day, utc_offset)
    seconds = 86400

    for variable in variable_dict.keys():
        variable_id = variable_dict[variable]
        measurement = line[variable]
        if measurement is None or type(measurement) == str:
            measurement = settings.MISSING_VALUE

        records_list.append((station_id, variable_id, seconds, parsed_date, measurement, None, None, None, None, None,
                             None, None, None, None, True))

    return records_list

def find_station_by_name(station_name):
    station = None   
    try:
        station = Station.objects.get(name=station_name, is_automatic=False)
    except (ObjectDoesNotExist, MultipleObjectsReturned) as e:
        try:
            station = Station.objects.get(alias_name=station_name, is_automatic=False)
        except (ObjectDoesNotExist, MultipleObjectsReturned) as e:
            try:
                station_name_for_query = station_name + ','
                station = Station.objects.annotate(names=Concat('alternative_names', Value(','))).get(
                            names=station_name_for_query, is_automatic=False)
            except (ObjectDoesNotExist, MultipleObjectsReturned) as e:
                raise Exception(f"Failed to find station by name '{station_name}'. {repr(e)}")

    return station

@shared_task
def read_file(filename, highfrequency_data=False, station_object=None, utc_offset=-360, override_data_on_conflict=False):
    """Read a manual data file and return a seq of records or nil in case of error"""

    logger.info('processing %s' % filename)

    start = time.time()
    reads = []
    date_info = None
    try:
        source = pd.ExcelFile(filename)

        # iterate over the sheets
        for sheet_name in source.sheet_names:
            sheet_raw_data = source.parse(sheet_name, skipfooter=2, na_filter=False, names=column_names, usecols='A:Q')
            if not sheet_raw_data.empty:
                header = sheet_raw_data[0:1]
                sheet_data = sheet_raw_data[7:]

                # get the sheet station info
                station_name = sheet_name.strip()
                station = find_station_by_name(station_name)

                station_id = station.id

                # get the sheet data info 
                if date_info is None:
                    sheet_month = header['sunshine'][0].replace('MONTH: ', '').strip()
                    sheet_year = header['evaporation_24h_thrown_back'][0].replace('YEAR: ', '').strip()
                    date_info = {'month': sheet_month, 'year': sheet_year}
                else:
                    sheet_month = date_info['month']
                    sheet_year = date_info['year']

                # filter the sheet day
                month_datetime = datetime.datetime.strptime(f'{sheet_month} {sheet_year}', '%B %Y')
                first_month_day, last_month_day = calendar.monthrange(month_datetime.year, month_datetime.month)
                
                sheet_data = sheet_data[pd.to_numeric(sheet_data['day'], errors='coerce').notnull()]
                for index, row in sheet_data[sheet_data['day'] <= last_month_day].iterrows():
                    for line_data in parse_line(row, station_id, month_datetime, utc_offset):
                        reads.append(line_data)

    except FileNotFoundError as fnf:
        logger.error(repr(fnf))
        print('No such file or directory {}.'.format(filename))
        raise
    except Exception as e:
        logger.error(repr(e))
        raise

    if highfrequency_data:
        insert_hf(reads, override_data_on_conflict)
    else:
        insert(reads, override_data_on_conflict)

    end = time.time()

    logger.info(f'Processing file {filename} in {end - start} seconds, '
                f'returning #reads={len(reads)}.')

    return reads
