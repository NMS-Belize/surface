import logging
import time
from csv import reader as csv_reader
from datetime import datetime

import pytz
from celery import shared_task

from wx.decoders.insert_raw_data import insert
from wx.decoders.insert_hf_data import insert as insert_hf
from wx.models import VariableFormat, Station, StationVariable
from wx.utils import update_station_variables

logger = logging.getLogger('surface.toa5')
db_logger = logging.getLogger('db')

FORMAT = "TOA5"


def convert_string_2_datetime(text, utc_offset):
    date, time = text.split(" ")

    year, month, day = date.split("-")

    hour, minute, second = time.split(":")

    datetime_offset = pytz.FixedOffset(utc_offset)
    date1 = datetime(int(year), int(month), int(day), int(hour), int(minute), int(second), 0, tzinfo=datetime_offset)

    return date1


def get_current_station_variable(station_variables_dict, variable_id):
    try:
        return station_variables_dict[variable_id]
    except Exception:
        return None


def parse_line(line, station, lookup_table, station_variables_dict, utc_offset):
    """Remove quotes and returns the line"""
    date_info = convert_string_2_datetime(line[0], utc_offset)

    line_data = []

    for index in range(len(lookup_table)):

        if lookup_table[index] is not None and line[index] != 'NAN' and line[index] != '':
            line_data.append((station.id, lookup_table[index]['variable_id'],
                              lookup_table[index]['seconds'], date_info,
                              float(line[index]), 1, None, None, None,
                              None, None, None, None, None, False))

    return line_data


def parse_first_line_header(line):
    """Parse the first line of the header and extract station code"""

    station_code_name = line[1]

    station_code = station_code_name.split('_')[0]

    return station_code


def parse_second_line_header(station, line):
    """Parse the second line of the header and extract the column names"""

    column_names = line

    logger.info(f"column_names={column_names}")

    variable_format_list = VariableFormat.objects.all()

    lookup_table = {}
    in_file_station_variables = set()

    for variable_format in variable_format_list:

        # check if lookup_key is not duplicated
        if variable_format.lookup_key in lookup_table:
            db_logger.warning(f"key {variable_format.lookup_key} is already "
                            f"present in lookup table: {variable_format}")

        lookup_table[variable_format.lookup_key] = {
            'variable_id': variable_format.variable.id,
            'seconds': variable_format.interval.seconds
        }

    result = {}

    for index, column_name in enumerate(column_names):

        if column_name in lookup_table.keys():
            variable = lookup_table[column_name]
            in_file_station_variables.add(variable['variable_id'])
        else:
            db_logger.warning(f'Variable {column_name} not found while parsing document from station {station.name}')
            variable = None

        result[index] = variable

    # associate new variable on station
    update_station_variables(station, in_file_station_variables)

    return result


def read_header(file):
    """Read a TOA5 file and return a map with metadata extracted from the header"""
    pass


@shared_task
def read_file(filename, highfrequency_data=False, station_object=None, utc_offset=-360, override_data_on_conflict=False):
    """Read a TOA5 file and return a seq of records or nil in case of error"""

    logger.info('processing %s' % filename)

    start = time.time()

    reads = []

    try:
        with open(filename, 'r', encoding='UTF-8') as source:

            # replace NULL byte
            reader = csv_reader(line.replace('\0', '') for line in source)
            if station_object is None:
                station_code = filename.split('/')[-1].split('_')[0]
                # station_code = parse_first_line_header(next(reader))
                station = Station.objects.get(code=station_code)
            else:
                station = station_object
                station_code = station.code

            next(reader)
            lookup_table = parse_second_line_header(station, next(reader))

            next(reader)
            next(reader)

            station_variables_list = StationVariable.objects.filter(station_id=station.id)
            station_variables_dict = {}

            for station_variable in station_variables_list:
                station_variables_dict[station_variable.variable_id] = station_variable

            for r in reader:
                for line_data in parse_line(r, station, lookup_table, station_variables_dict, utc_offset):
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
