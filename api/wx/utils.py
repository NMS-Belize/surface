import datetime
import logging
import os
import pyoscar
import shutil

from builtins import IndexError

import matplotlib as mpl
import numpy as np
import rasterio
from django.conf import settings
from django.contrib.gis.geos import Point
from django.db import connection
from rasterio import RasterioIOError

from wx.enums import QualityFlagEnum
from wx.models import Watershed, District, StationVariable

mpl.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.colors import BoundaryNorm
import pandas as pd
import cartopy.crs as ccrs
from metpy.interpolate import interpolate_to_grid, remove_nan_observations, remove_repeat_coordinates
from io import BytesIO

from psycopg2 import sql


def get_altitude(lon, lat):
    try:

        dataset = rasterio.open(os.path.join(settings.SURFACE_DATA_DIR, 'srtm_19_09.tif'))

        band1 = dataset.read(1)

        row, col = dataset.index(float(lon), float(lat))

        altitude = band1[row, col]

    except (IndexError, RasterioIOError) as e:

        logging.exception(e)

        altitude = -999

    return altitude


def get_watershed(lon, lat):
    pnt = Point(lon, lat)

    try:

        watershed = Watershed.objects.get(geom__contains=pnt)

    except Watershed.DoesNotExist as e:

        logging.exception(e)

        return 'NOT FOUND'

    return watershed.watershed


def get_district(lon, lat):
    pnt = Point(lon, lat)

    try:

        district = District.objects.get(geom__contains=pnt)

    except District.DoesNotExist as e:

        logging.exception(e)

        return 'NOT FOUND'

    return district.district


def parse_bool_value(value):
    if value is None:
        return None

    return bool(value)


def parse_float_value(value):
    if not value:
        return None

    return float(value)


def parse_int_value(value):
    if not value:
        return None

    return int(value)


def verify_none_value(first_value, second_value):
    if first_value is not None:
        return first_value
    return second_value


def get_basic_map(proj):
    """Make our basic default map for plotting"""
    fig = plt.figure(figsize=(8, 10))
    view = fig.add_axes([.05, 0, .95, .95], projection=proj)
    view.set_extent([-90, -87, 15, 19])

    view.outline_patch.set_visible(False)
    view.background_patch.set_visible(False)

    # view.add_feature(cfeature.COASTLINE)
    # view.add_feature(cfeature.BORDERS, linestyle=':')
    return fig, view


def get_interpolation_data(data):
    df = pd.DataFrame.from_records(data)

    latitude_list = df['station__latitude']
    longitude_list = df['station__longitude']
    value_list = df['value']

    latitude_list, longitude_list, value_list = remove_nan_observations(longitude_list, latitude_list, value_list)
    latitude_list, longitude_list, value_list = remove_repeat_coordinates(longitude_list, latitude_list, value_list)

    return latitude_list, longitude_list, value_list


def get_interpolation_proj(latitude_list, longitude_list, value):
    from_proj = ccrs.Geodetic()
    to_proj = ccrs.AlbersEqualArea(central_longitude=-88.429595, central_latitude=17.202212)  # Belize location

    proj_points = to_proj.transform_points(from_proj, longitude_list, latitude_list)

    return (proj_points[:, 0], proj_points[:, 1], value, to_proj)


def get_boundaries_levels(value_list):
    max_value = int(value_list.max()) + 1
    min_value = int(value_list.min()) - 1

    if max_value == min_value:
        max_value = max_value + 5
        min_value = min_value - 5

    return list(range(min_value, max_value, 1))


def get_interpolation_image(interpolation_values):
    latitude_list, longitude_list, value_list = get_interpolation_data(interpolation_values)
    latitude_list, longitude_list, value_list, to_proj = get_interpolation_proj(latitude_list, longitude_list,
                                                                                value_list)

    gx, gy, img = interpolate_to_grid(x=latitude_list, y=longitude_list, z=value_list, interp_type='linear', hres=7500)

    levels = get_boundaries_levels(value_list)
    cmap = plt.get_cmap('magma')
    norm = BoundaryNorm(levels, ncolors=cmap.N, clip=True)

    img = np.ma.masked_where(np.isnan(img), img)
    fig, view = get_basic_map(to_proj)
    mmb = view.pcolormesh(gx, gy, img, cmap=cmap, norm=norm)
    # fig.colorbar(mmb, shrink=.4, pad=0, boundaries=levels)

    figfile = BytesIO()
    plt.savefig(figfile, format='png', transparent=True)

    return figfile.getvalue()


def update_station_variables(station, in_file_station_variables):
    current_station_variables = set(
        StationVariable.objects.filter(station=station).values_list('variable_id', flat=True))
    unregistered_station_variables = in_file_station_variables - current_station_variables

    for unregistered_station_variable in unregistered_station_variables:
        StationVariable.objects.create(station=station, variable_id=unregistered_station_variable)


def get_monthly_or_yearly(search_type, station, variable, search_date_start, search_date_end, source):
    response = {
        'results': {},
        'messages': [],
    }

    day_start = search_date_start[0:10]
    day_end = search_date_end[0:10]

    date_group = 'EXTRACT(year from day) as year'
    group_by = '1, 2, 3, 4, 5, 6, 12, 13, 14, 15, 16'
    order_by = '16'
    if source == 'monthly_summary':
        date_group += ',EXTRACT(month from day) as month'
        group_by = '1, 2, 3, 4, 5, 6, 12, 13, 14, 15, 16, 17'
        order_by = '16, 17'

    if search_type == 'station':
        sql_string = f'''
            SELECT                           
                a.station_id,
                a.variable_id,           
                b.symbol,
                b.name,
                c.name,
                c.symbol,
                min(a.min_value) min_value,
                max(a.max_value) max_value,
                avg(a.avg_value) avg_value,
                sum(a.sum_value) sum_value,
                count(a.sum_value),
                d.name,
                b.color,
                b.default_representation,
                b.sampling_operation_id,
                {date_group}
                FROM daily_summary a
            INNER JOIN wx_variable b ON a.variable_id=b.id
            INNER JOIN wx_unit c ON b.unit_id=c.id
            INNER JOIN wx_measurementvariable d ON b.measurement_variable_id=d.id
                where station_id={station}
                and day > '{day_start}'
                and day <= '{day_end}'
            GROUP BY {group_by}
            ORDER BY {order_by} ASC;
        '''
    elif search_type == 'stationvariable':
        sql_string = f'''
            SELECT                       
                a.station_id,
                a.variable_id,           
                b.symbol,
                b.name,
                c.name,
                c.symbol,
                min(a.min_value) min_value,
                max(a.max_value) max_value,
                avg(a.avg_value) avg_value,
                sum(a.sum_value) sum_value,
                count(a.sum_value),
                d.name,
                b.color,
                b.default_representation,
                b.sampling_operation_id
                {date_group}
                FROM daily_summary a
            INNER JOIN wx_variable b ON a.variable_id=b.id
            INNER JOIN wx_unit c ON b.unit_id=c.id
            INNER JOIN wx_measurementvariable d ON b.measurement_variable_id=d.id
                where station_id={station}
                and variable_id={variable}
                and day > '{day_start}'
                and day <= '{day_end}'
            GROUP BY {group_by}
            ORDER BY 1,2 ASC;
        '''

    with connection.cursor() as cursor:
        cursor.execute(sql_string)
        rows = cursor.fetchall()
        for row in rows:
            if not row[11] in response['results'].keys():
                response['results'][row[11]] = {}

            if not row[2] in response['results'][row[11]].keys():
                response['results'][row[11]][row[2]] = {
                    'color': row[12],
                    'default_representation': row[13],
                    'data': [],
                    'unit': row[5],
                }

            year = int(row[15])
            obj = {
                'station': row[0],
                'year': year,
                'variable': row[1],
                'measurementvariable': row[11]
            }

            if source == 'monthly_summary':
                month = int(row[16])
                if month < 10:
                    obj['date'] = f'{year}-0{month}'
                else:
                    obj['date'] = f'{year}-{month}'
                obj['month'] = month
            else:
                obj['date'] = year

            if row[11] in [6, 7]:
                obj['value'] = round(row[9], 2)  # sum_value
            elif row[11] == 3:
                obj['value'] = round(row[6], 2)  # min_value
            elif row[11] == 4:
                obj['value'] = round(row[7], 2)  # max_value
            else:
                obj['value'] = round(row[8], 2)  # avg_value

            response['results'][row[11]][row[2]]['data'].append(obj)

    return response


def get_raw_data(search_type, search_value, search_value2, search_date_start, search_date_end, source='raw_data'):
    sql_string = ""

    response = {
        'results': {},
        'messages': [],
    }

    try:
        if (source == 'daily_summary' or source == 'monthly_summary' or source == 'yearly_summary'):
            start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%d')
        else:
            start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%dT%H:%M:%SZ')
    except ValueError as err:
        try:
            start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%dT%H:%MZ')
        except ValueError as err:
            message = 'ValueError: {}'.format(err)
            response['messages'].append(message)
            return response

    try:
        if (source == 'daily_summary' or source == 'monthly_summary' or source == 'yearly_summary'):
            end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%d')
        else:
            end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%dT%H:%M:%SZ')
    except ValueError as err:
        try:
            end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%dT%H:%MZ')
        except ValueError as err:
            message = 'ValueError: {}'.format(err)
            response['messages'].append(message)
            return response

    delta = end_date - start_date

    if source == 'raw_data':
        value_variable = sql.Identifier('measured')
        max_days = 15
    elif source == 'hourly_summary':
        value_variable = sql.SQL(', ').join(map(sql.Identifier, ['min_value', 'max_value', 'avg_value', 'sum_value']))
        max_days = 30
    elif source == 'daily_summary':
        value_variable = sql.SQL(', ').join(map(sql.Identifier, ['min_value', 'max_value', 'avg_value', 'sum_value']))
        max_days = 365
    elif source == 'monthly_summary' or source == 'yearly_summary':
        value_variable = sql.SQL(', ').join(map(sql.Identifier, ['min_value', 'max_value', 'avg_value', 'sum_value']))
        max_days = None
    # else:
    #     return get_monthly_or_yearly(search_type, search_value, search_value2, search_date_start, search_date_end, source)

    datetime_variable = sql.Identifier('datetime')
    if source == 'daily_summary':
        datetime_variable = sql.Identifier('day')
    if source == 'monthly_summary' or source == 'yearly_summary':
        datetime_variable = sql.Identifier('date')

    if max_days is not None and delta.days > max_days:  # Restrict queries to max two days
        message = 'Interval between search_date_start and search_date_end is greater than two days.'
        response['messages'].append(message)
        return response

    if search_type is not None and search_type == 'variable':

        if source == 'raw_data':
            sql_string = """
                SELECT station_id,
                    variable_id,
                    b.symbol,
                    b.name,
                    c.name,
                    c.symbol,
                    extract(epoch from {}),
                    d.name,
                    b.color,
                    b.default_representation,
                    b.sampling_operation_id,
                    q.name as quality_flag,
                    q.color as flag_color,
                    {}
                FROM {} a
                JOIN wx_variable b ON a.variable_id=b.id
                JOIN wx_unit c ON b.unit_id=c.id
                JOIN wx_measurementvariable d ON b.measurement_variable_id=d.id
                JOIN wx_qualityflag q ON a.quality_flag=q.id
            WHERE d.id=%s 
            AND {} >= %s 
            AND {} <= %s"""
        else:
            sql_string = """
                SELECT station_id,
                    variable_id,
                    b.symbol,
                    b.name,
                    c.name,
                    c.symbol,
                    extract(epoch from {}),
                    d.name,
                    b.color,
                    b.default_representation,
                    b.sampling_operation_id,
                    {}
                FROM {} a
                JOIN wx_variable b ON a.variable_id=b.id
                JOIN wx_unit c ON b.unit_id=c.id
                JOIN wx_measurementvariable d ON b.measurement_variable_id=d.id
            WHERE d.id=%s 
            AND {} >= %s 
            AND {} <= %s"""

    if search_type is not None and search_type == 'station':
        if source == 'raw_data':
            sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   c.name,
                   c.symbol,
                   extract(epoch from {}),
                   d.name,
                   b.color,
                   b.default_representation,
                   b.sampling_operation_id,
                   q.name as quality_flag,
                   q.color as flag_color,
                   {}
            FROM {} a
            JOIN wx_variable b ON a.variable_id=b.id
            JOIN wx_unit c ON b.unit_id=c.id
            JOIN wx_measurementvariable d ON b.measurement_variable_id=d.id
            JOIN wx_qualityflag q ON a.quality_flag=q.id
            WHERE station_id=%s 
              AND {} >= %s 
              AND {} <= %s
        """
        else:
            sql_string = """
                SELECT station_id,
                    variable_id,
                    b.symbol,
                    b.name,
                    c.name,
                    c.symbol,
                    extract(epoch from {}),
                    d.name,
                    b.color,
                    b.default_representation,
                    b.sampling_operation_id,
                    {}
            FROM {} a
            JOIN wx_variable b ON a.variable_id=b.id
            JOIN wx_unit c ON b.unit_id=c.id
            JOIN wx_measurementvariable d ON b.measurement_variable_id=d.id
            WHERE station_id=%s 
              AND {} >= %s 
              AND {} <= %s
        """

    if search_type is not None and search_type == 'stationvariable':
        sql_string = """
            SELECT station_id,
                   variable_id,
                   b.symbol,
                   b.name,
                   c.name,
                   c.symbol,
                   extract(epoch from {}),
                   d.name,
                   b.color,
                   b.default_representation,
                   b.sampling_operation_id,
                   {}
            FROM {} a
            JOIN wx_variable b ON a.variable_id=b.id
            JOIN wx_unit c ON b.unit_id=c.id
            JOIN wx_measurementvariable d ON b.measurement_variable_id=d.id
            WHERE station_id=%s 
              AND variable_id=%s 
              AND {} >= %s 
              AND {} <= %s
        """

    if sql_string:
        sql_string += " ORDER BY {}"

        with connection.cursor() as cursor:

            if search_type is not None and search_type == 'stationvariable':
                cursor.execute(sql.SQL(sql_string).format(datetime_variable, value_variable, sql.Identifier(source),
                                                          datetime_variable, datetime_variable, datetime_variable),
                               (search_value, search_value2, search_date_start, search_date_end))
            else:
                cursor.execute(sql.SQL(sql_string).format(datetime_variable, value_variable, sql.Identifier(source),
                                                          datetime_variable, datetime_variable, datetime_variable),
                               (search_value, search_date_start, search_date_end))

            rows = cursor.fetchall()

            for row in rows:

                if not row[7] in response['results'].keys():
                    response['results'][row[7]] = {}

                if not row[2] in response['results'][row[7]].keys():
                    response['results'][row[7]][row[2]] = {
                        'color': row[8],
                        'default_representation': row[9],
                        'data': [],
                        'unit': row[5],
                    }

                obj = {
                    'station': row[0],
                    'date': row[6] * 1000,
                    # 'year': row[6].year,
                    # 'month': row[6].month,
                    # 'day': row[6].day,
                    'variable': row[2],
                    'measurementvariable': row[7],
                }
                # if source != "daily_summary":
                #     obj['hour'] = row[6].hour
                #     obj['minute'] = row[6].minute

                if source == 'raw_data':
                    obj['value'] = round(row[13], 2)
                    obj['quality_flag'] = row[11]
                    obj['flag_color'] = row[12]
                else:
                    if row[10] in [6, 7]:
                        obj['value'] = round(row[14], 2)  # sum_value
                    elif row[10] == 3:
                        obj['value'] = round(row[11], 2)  # min_value
                    elif row[10] == 4:
                        obj['value'] = round(row[12], 2)  # max_value
                    else:
                        obj['value'] = round(row[13], 2)  # avg_value

                # obj['variable']['symbol'] = row[2]
                # obj['variable']['name'] = row[3]
                # obj['variable']['unit_name'] = row[4]
                # obj['variable']['unit_symbol'] = row[5]

                response['results'][row[7]][row[2]]['data'].append(obj)

            return response

    return response


def get_station_raw_data(search_type, search_values, search_value2, search_date_start, search_date_end, search_filter,
                         source='raw_data'):
    sql_string = ""

    response = {
        'results': {},
        'messages': [],
    }

    try:
        if (source == 'daily_summary' or source == 'monthly_summary' or source == 'yearly_summary'):
            start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%d')
        else:
            start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%dT%H:%M:%SZ')
    except ValueError as err:
        try:
            start_date = datetime.datetime.strptime(search_date_start, '%Y-%m-%dT%H:%MZ')
        except ValueError as err:
            message = 'ValueError: {}'.format(err)
            response['messages'].append(message)
            return response

    try:
        if (source == 'daily_summary' or source == 'monthly_summary' or source == 'yearly_summary'):
            end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%d')
        else:
            end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%dT%H:%M:%SZ')
    except ValueError as err:
        try:
            end_date = datetime.datetime.strptime(search_date_end, '%Y-%m-%dT%H:%MZ')
        except ValueError as err:
            message = 'ValueError: {}'.format(err)
            response['messages'].append(message)
            return response

    delta = end_date - start_date

    if source == 'raw_data':
        value_variable = sql.Identifier('measured')
        max_days = 7
    elif source == 'hourly_summary':
        value_variable = sql.SQL(', ').join(map(sql.Identifier, ['min_value', 'max_value', 'avg_value', 'sum_value']))
        max_days = 30
    elif source == 'daily_summary':
        value_variable = sql.SQL(', ').join(map(sql.Identifier, ['min_value', 'max_value', 'avg_value', 'sum_value']))
        max_days = 365
    elif source == 'monthly_summary' or source == 'yearly_summary':
        value_variable = sql.SQL(', ').join(map(sql.Identifier, ['min_value', 'max_value', 'avg_value', 'sum_value']))
        max_days = None
    # else:
    #     return get_monthly_or_yearly(search_type, search_value, search_value2, search_date_start, search_date_end, source)

    datetime_variable = sql.Identifier('datetime')
    if source == 'daily_summary':
        datetime_variable = sql.Identifier('day')
    if source == 'monthly_summary' or source == 'yearly_summary':
        datetime_variable = sql.Identifier('date')

    if max_days is not None and delta.days > max_days:  # Restrict queries to max two days
        message = 'Interval between search_date_start and search_date_end is greater than two days.'
        response['messages'].append(message)
        return response

    if search_type is not None and search_type == 'variable':
        if source == 'raw_data':
            sql_string = """
                SELECT a.station_id,
                    a.variable_id,
                    s.name,
                    b.name,
                    c.name,
                    c.symbol,
                    extract(epoch from {}),
                    b.name,
                    b.color,
                    b.default_representation,
                    b.sampling_operation_id,
                    q.name as quality_flag,
                    q.color as flag_color,
                    {}
                FROM {} a
                JOIN wx_variable b ON a.variable_id=b.id
                JOIN wx_unit c ON b.unit_id=c.id
                JOIN wx_qualityflag q ON a.quality_flag=q.id
                JOIN wx_stationvariable sv ON b.id=sv.variable_id and a.station_id=sv.station_id
                JOIN wx_station s ON sv.station_id=s.id
            WHERE a.variable_id in %s 
            AND {} >= %s 
            AND {} <= %s
            AND a.station_id in %s"""
        else:
            sql_string = """
            SELECT a.station_id,
                   a.variable_id,
                   s.name,
                   b.name,
                   c.name,
                   c.symbol,
                   extract(epoch from {}),
                   b.name,
                   b.color,
                   b.default_representation,
                   b.sampling_operation_id,
                   {}
            FROM {} a
            JOIN wx_variable b ON a.variable_id=b.id
            JOIN wx_unit c ON b.unit_id=c.id
            JOIN wx_stationvariable sv ON b.id=sv.variable_id and a.station_id=sv.station_id
            JOIN wx_station s ON sv.station_id=s.id
        WHERE a.variable_id in %s 
          AND {} >= %s 
          AND {} <= %s
          AND a.station_id in %s"""

    if sql_string:
        sql_string += " ORDER BY {}"

        with connection.cursor() as cursor:

            if search_type is not None and search_type == 'stationvariable':
                cursor.execute(sql.SQL(sql_string).format(datetime_variable, value_variable, sql.Identifier(source),
                                                          datetime_variable, datetime_variable, datetime_variable),
                               (search_values, search_value2, search_date_start, search_date_end, search_filter))
            else:
                cursor.execute(sql.SQL(sql_string).format(datetime_variable, value_variable, sql.Identifier(source),
                                                          datetime_variable, datetime_variable, datetime_variable),
                               (search_values, search_date_start, search_date_end, search_filter))

            rows = cursor.fetchall()

            for row in rows:

                if not row[7] in response['results'].keys():
                    response['results'][row[7]] = {}

                if not row[2] in response['results'][row[7]].keys():
                    response['results'][row[7]][row[2]] = {
                        'color': row[8],
                        'default_representation': row[9],
                        'data': [],
                        'unit': row[5],
                    }

                obj = {
                    'station': row[0],
                    'date': row[6] * 1000,
                    'variable': row[2],
                    'measurementvariable': row[7],
                }

                if source == 'raw_data':
                    obj['value'] = round(row[13], 2)
                    obj['quality_flag'] = row[11]
                    obj['flag_color'] = row[12]
                else:
                    if row[10] in [6, 7]:
                        obj['value'] = round(row[14], 2)  # sum_value
                    elif row[10] == 3:
                        obj['value'] = round(row[11], 2)  # min_value
                    elif row[10] == 4:
                        obj['value'] = round(row[12], 2)  # max_value
                    else:
                        obj['value'] = round(row[13], 2)  # avg_value

                response['results'][row[7]][row[2]]['data'].append(obj)

            return response

    return response