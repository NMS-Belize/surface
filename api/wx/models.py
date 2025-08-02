import logging
import time
from datetime import datetime as dt

import pytz
from colorfield.fields import ColorField
from django.contrib.auth.models import Group
from django.contrib.gis.db import models
from django.core.validators import MinValueValidator, MaxValueValidator
from django.urls import reverse
from django.utils.timezone import now
from croniter import croniter
from django.core.exceptions import ValidationError

from wx.enums import FlashTypeEnum

from timescale.db.models.models import TimescaleModel
from timescale.db.models.fields import TimescaleDateTimeField
from timescale.db.models.managers import TimescaleManager
from simple_history.models import HistoricalRecords
from django.utils.translation import gettext_lazy # Enumaretor
from datetime import date
from ckeditor.fields import RichTextField

class BaseModel(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


class Decoder(BaseModel):
    name = models.CharField(
        max_length=40
    )

    description = models.CharField(
        max_length=256
    )

    class Meta:
        ordering = ['name']

    def __str__(self):
        return self.name


class Country(BaseModel):
    notation = models.CharField(max_length=16)
    name = models.CharField(max_length=256, unique=True)
    description = models.CharField(max_length=256, null=True, blank=True)
    class Meta:
        verbose_name_plural = "countries"

    def __str__(self):
        return self.name


class Interval(BaseModel):
    symbol = models.CharField(max_length=8, )

    description = models.CharField(max_length=40)

    default_query_range = models.IntegerField(default=0)

    seconds = models.IntegerField(null=True)

    class Meta:
        ordering = ('symbol',)

    def __str__(self):
        return self.symbol


class PhysicalQuantity(BaseModel):
    name = models.CharField(
        max_length=16,
        unique=True
    )

    class Meta:
        ordering = ('name',)

    def __str__(self):
        return self.name


class MeasurementVariable(BaseModel):
    name = models.CharField(
        max_length=40,
        unique=True
    )

    physical_quantity = models.ForeignKey(
        PhysicalQuantity,
        on_delete=models.DO_NOTHING
    )

    class Meta:
        ordering = ('name',)

    def __str__(self):
        return self.name


class CodeTable(BaseModel):
    name = models.CharField(
        max_length=45,
        unique=True
    )

    description = models.CharField(
        max_length=256,
    )

    def __str__(self):
        return self.name


class Unit(BaseModel):
    symbol = models.CharField(
        max_length=16,
        unique=True
    )

    name = models.CharField(
        max_length=256,
        unique=True
    )

    class Meta:
        ordering = ('name',)

    def __str__(self):
        return self.name


class SamplingOperation(BaseModel):
    """Old sampling_operations table"""
    symbol = models.CharField(
        max_length=5,
        unique=True
    )

    name = models.CharField(
        max_length=40,
        unique=True
    )

    class Meta:
        ordering = ('symbol',)

    def __str__(self):
        return self.name


class Variable(BaseModel):
    """Old element table"""
    variable_type = models.CharField(
        max_length=40,
    )

    symbol = models.CharField(
        max_length=8,
    )

    name = models.CharField(
        max_length=40,
    )

    sampling_operation = models.ForeignKey(
        SamplingOperation,
        on_delete=models.DO_NOTHING,
        null=True,
        blank=True,
    )

    measurement_variable = models.ForeignKey(
        MeasurementVariable,
        on_delete=models.DO_NOTHING,
        null=True,
        blank=True,
    )

    unit = models.ForeignKey(
        Unit,
        on_delete=models.DO_NOTHING,
        null=True,
        blank=True,
    )

    precision = models.IntegerField(
        null=True,
        blank=True,
    )

    scale = models.IntegerField(
        null=True,
        blank=True,
    )

    code_table = models.ForeignKey(
        CodeTable,
        on_delete=models.DO_NOTHING,
        null=True,
        blank=True,
    )

    color = ColorField(default='#FF0000', null=True, blank=True)

    range_min = models.FloatField(null=True, blank=True,)
    range_max = models.FloatField(null=True, blank=True,)

    range_min_hourly = models.FloatField(null=True, blank=True,)
    range_max_hourly = models.FloatField(null=True, blank=True,)

    step = models.FloatField(null=True, blank=True,)
    step_hourly = models.FloatField(null=True, blank=True,)

    persistence = models.FloatField(null=True, blank=True,)    
    persistence_hourly = models.FloatField(null=True, blank=True,)

    persistence_window = models.IntegerField(null=True, blank=True, verbose_name = 'Persistence Window (in hours)',)    
    persistence_window_hourly = models.IntegerField(null=True, blank=True, verbose_name = 'Persistence Window hourly (in hours)',)


    default_representation = models.CharField(
        max_length=60,
        null=True,
        blank=True,
        default='line',
        choices=[('line', 'Line'), ('point', 'Point'), ('bar', 'Bar'), ('column', 'Column')])

    class Meta:
        ordering = ('name',)

    def __str__(self):
        return self.name


class DataSource(BaseModel):
    symbol = models.CharField(max_length=8, unique=True)
    name = models.CharField(max_length=32, unique=True)
    base_url = models.URLField(null=True)
    location = models.CharField(max_length=256, null=True)

    class Meta:
        verbose_name = "data source"
        verbose_name_plural = "data sources"

    def __str__(self):
        return self.name


class StationProfile(BaseModel):
    name = models.CharField(max_length=45)
    description = models.CharField(max_length=256)
    color = models.CharField(max_length=7)
    is_automatic = models.BooleanField(default=False)
    is_manual = models.BooleanField(default=True)

    class Meta:
        verbose_name = "station profile"
        verbose_name_plural = "station profiles"

    def __str__(self):
        return self.name


class AdministrativeRegionType(BaseModel):
    name = models.CharField(max_length=45)

    class Meta:
        verbose_name = "administrative region type"
        verbose_name_plural = "administrative region types"

    def __str__(self):
        return self.name


class AdministrativeRegion(BaseModel):
    name = models.CharField(max_length=45)
    country = models.ForeignKey(Country, on_delete=models.DO_NOTHING)
    administrative_region_type = models.ForeignKey(AdministrativeRegionType, on_delete=models.DO_NOTHING)

    class Meta:
        verbose_name = "administrative region"
        verbose_name_plural = "administrative regions"

    def __str__(self):
        return self.name


class StationType(BaseModel):
    name = models.CharField(max_length=45)
    description = models.CharField(max_length=256)
    parent_type = models.ForeignKey('self', on_delete=models.DO_NOTHING, null=True)

    class Meta:
        verbose_name = "station type"
        verbose_name_plural = "station types"

    def __str__(self):
        return self.name


class StationCommunication(BaseModel):
    name = models.CharField(max_length=45)
    description = models.CharField(max_length=256)
    color = models.CharField(max_length=7)

    class Meta:
        verbose_name = "station communication"
        verbose_name_plural = "station communications"

    def __str__(self):
        return self.description


class WMOStationType(BaseModel):
    name = models.CharField(max_length=256, unique=True)
    description = models.CharField(max_length=256, null=True, blank=True)
    notation = models.CharField(max_length=256, null=True, blank=True)

    def __str__(self):
        return self.name


class WMORegion(BaseModel):
    name = models.CharField(max_length=256, unique=True)
    description = models.CharField(max_length=256, null=True, blank=True)
    notation = models.CharField(max_length=256, null=True, blank=True)

    def __str__(self):
        return self.name


class WMOProgram(BaseModel):
    name = models.CharField(max_length=256, unique=True)
    description = models.CharField(max_length=512, null=True, blank=True)
    notation = models.CharField(max_length=256, null=True, blank=True)
    path = models.CharField(max_length=256, null=True, blank=True)    

    def __str__(self):
        return self.name

class Watershed(models.Model):
    watershed = models.CharField(max_length=128)
    size = models.CharField(max_length=16)
    acres = models.FloatField()
    hectares = models.FloatField()
    shape_leng = models.FloatField()
    shape_area = models.FloatField()
    geom = models.MultiPolygonField(srid=4326)

class Station(BaseModel):    
    name = models.CharField(max_length=256)
    alias_name = models.CharField(max_length=256, null=True, blank=True)
    begin_date = models.DateTimeField(null=True)
    relocation_date = models.DateTimeField(null=True, blank=True)
    end_date = models.DateTimeField(null=True, blank=True)
    network = models.CharField(max_length=256, null=True, blank=True)
    longitude = models.FloatField(validators=[
        MinValueValidator(-180.), MaxValueValidator(180.)
    ])
    latitude = models.FloatField(validators=[
        MinValueValidator(-90.),
        MaxValueValidator(90.)
    ])
    elevation = models.FloatField(null=True)
    code = models.CharField(max_length=64)
    reference_station = models.ForeignKey('self',
        on_delete=models.SET_NULL,
        null=True,
        blank=True)
    wmo = models.IntegerField(
        null=True,
        blank=True
    )
    wigos = models.CharField(
        null=True,
        max_length=64,
        blank=True
    )

    is_active = models.BooleanField(default=False)
    is_automatic = models.BooleanField(default=True)
    organization = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    observer = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    watershed = models.CharField(
        max_length=256,
        null=True
    )
    z = models.FloatField(
        null=True,
        blank=True
    )
    datum = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    zone = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    ground_water_province = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    river_code = models.IntegerField(
        null=True,
        blank=True
    )
    river_course = models.CharField(
        max_length=64,
        null=True,
        blank=True
    )
    catchment_area_station = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    river_origin = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    easting = models.FloatField(
        null=True,
        blank=True
    )
    northing = models.FloatField(
        null=True,
        blank=True
    )
    river_outlet = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    river_length = models.IntegerField(
        null=True,
        blank=True
    )
    local_land_use = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    soil_type = models.CharField(
        max_length=64,
        null=True,
        blank=True
    )
    site_description = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    land_surface_elevation = models.FloatField(
        null=True,
        blank=True
    )
    screen_length = models.FloatField(
        null=True,
        blank=True
    )
    top_casing_land_surface = models.FloatField(
        null=True,
        blank=True
    )
    depth_midpoint = models.FloatField(
        null=True,
        blank=True
    )
    screen_size = models.FloatField(
        null=True,
        blank=True
    )
    casing_type = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    casing_diameter = models.FloatField(
        null=True,
        blank=True
    )
    existing_gauges = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    flow_direction_at_station = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    flow_direction_above_station = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    flow_direction_below_station = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    bank_full_stage = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    bridge_level = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    access_point = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    temporary_benchmark = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    mean_sea_level = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    data_type = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    frequency_observation = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    historic_events = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    other_information = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    profile = models.ForeignKey(
        StationProfile,
        on_delete=models.DO_NOTHING,
        null=True,
        blank=True
    )
    hydrology_station_type = models.CharField(
        max_length=64,
        null=True,
        blank=True
    )
    is_surface = models.BooleanField(default=True)  # options are surface or ground
    station_details = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    remarks = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )        
    country = models.ForeignKey(
        Country,
        on_delete=models.DO_NOTHING,
        null=True
    )
    region = models.CharField(
        max_length=256,
        null=True
    )
    data_source = models.ForeignKey(
        DataSource,
        on_delete=models.DO_NOTHING,
        null=True,
        blank=True
    )
    communication_type = models.ForeignKey(
        StationCommunication,
        on_delete=models.DO_NOTHING,
        null=True
    )
    utc_offset_minutes = models.IntegerField(
        validators=[
            MaxValueValidator(720),
            MinValueValidator(-720)
        ]
    )
    alternative_names = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    wmo_station_type = models.ForeignKey(
        WMOStationType,
        on_delete=models.DO_NOTHING,
        null=True,
        blank=True
    )
    wmo_region = models.ForeignKey(
        WMORegion,
        on_delete=models.DO_NOTHING,
        null=True,
        blank=True
    )
    wmo_program = models.ForeignKey(
        WMOProgram,
        on_delete=models.DO_NOTHING,
        null=True,
        blank=True
    )
    wmo_station_plataform = models.CharField(
        max_length=256,
        null=True,
        blank=True
    )
    operation_status = models.BooleanField(default=True)

    class Meta:
        unique_together = ('data_source', 'code')
        ordering = ('name',)

    def get_absolute_url(self):
        """Returns the url to access a particular instance of Station."""
        return reverse('station-detail', args=[str(self.id)])

    def __str__(self):
        return self.name + ' - ' + self.code


class StationVariable(BaseModel):
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    variable = models.ForeignKey(Variable, on_delete=models.DO_NOTHING)
    first_measurement = models.DateTimeField(null=True, blank=True)
    last_measurement = models.DateTimeField(null=True, blank=True)
    last_value = models.FloatField(null=True, blank=True)
    height = models.FloatField(null=True, blank=True)
    last_data_datetime = models.DateTimeField(null=True, blank=True)
    last_data_value = models.FloatField(null=True, blank=True)
    last_data_code = models.CharField(max_length=60, null=True, blank=True)

    class Meta:
        unique_together = ("station", "variable")
        ordering = ["station__id", "variable__id", ]


class QualityFlag(BaseModel):
    symbol = models.CharField(max_length=8, unique=True)
    name = models.CharField(max_length=256, unique=True)
    color = ColorField(default='#FF0000', null=True, blank=True)

    def __str__(self):
        return self.name


def document_directory_path(instance, filename):
    # file will be uploaded to MEDIA_ROOT/user_<id>/<filename>
    path_to_file = 'documents/{0}_{1}.{2}'.format(instance.station.code, time.strftime("%Y%m%d_%H%M%S"),
                                                  filename.split('.')[-1])
    logging.info(f"Saving file {filename} in {path_to_file}")
    return path_to_file


class Document(BaseModel):
    alias = models.CharField(max_length=256, null=True)
    file = models.FileField(upload_to=document_directory_path)
    station = models.ForeignKey(Station, on_delete=models.CASCADE)
    processed = models.BooleanField(default=False)
    decoder = models.ForeignKey(Decoder, on_delete=models.CASCADE, null=True, blank=True)

    def __str__(self):
        return self.file.name


class DataFile(BaseModel):
    ready_at = models.DateTimeField(null=True, blank=True)
    ready = models.BooleanField(default=False)
    initial_date = models.DateTimeField(null=True, blank=True)
    final_date = models.DateTimeField(null=True, blank=True)
    source = models.CharField(max_length=30, null=False, blank=False, default="Raw data")
    lines = models.IntegerField(null=True, blank=True, default=None)
    prepared_by = models.CharField(max_length=256, null=True, blank=True)
    interval_in_seconds = models.IntegerField(null=True, blank=True)

    def __str__(self):
        return 'file ' + str(self.id)


class DataFileStation(BaseModel):
    datafile = models.ForeignKey(DataFile, on_delete=models.CASCADE)
    station = models.ForeignKey(Station, on_delete=models.CASCADE)


class DataFileVariable(BaseModel):
    datafile = models.ForeignKey(DataFile, on_delete=models.CASCADE)
    variable = models.ForeignKey(Variable, on_delete=models.CASCADE)


class StationFile(BaseModel):
    name = models.CharField(max_length=256, null=True)
    file = models.FileField(upload_to='station_files/%Y/%m/%d/')
    station = models.ForeignKey(Station, on_delete=models.CASCADE)

    def __str__(self):
        return self.name


class Format(BaseModel):
    name = models.CharField(
        max_length=40,
        unique=True,
    )

    description = models.CharField(
        max_length=256,
    )

    class Meta:
        ordering = ['name']

    def __str__(self):
        return self.name


class VariableFormat(BaseModel):
    variable = models.ForeignKey(
        Variable,
        on_delete=models.DO_NOTHING,
    )

    format = models.ForeignKey(
        Format,
        on_delete=models.DO_NOTHING,
    )

    interval = models.ForeignKey(
        Interval,
        on_delete=models.DO_NOTHING,
    )

    lookup_key = models.CharField(
        max_length=255,
    )

    class Meta:
        ordering = ['variable', 'format', ]

    def __str__(self):
        return '{} {}'.format(self.variable, self.format)


class PeriodicJobType(BaseModel):
    name = models.CharField(
        max_length=40,
        unique=True,
    )

    description = models.CharField(
        max_length=256,
    )

    class Meta:
        ordering = ['name']

    def __str__(self):
        return self.name


class PeriodicJob(BaseModel):
    periodic_job_type = models.ForeignKey(
        PeriodicJobType,
        on_delete=models.DO_NOTHING,
    )

    station = models.ForeignKey(
        Station,
        on_delete=models.DO_NOTHING,
    )

    is_running = models.BooleanField(
        default=False,
    )

    last_record = models.IntegerField(
        default=0,
    )

    class Meta:
        ordering = ('station', 'periodic_job_type',)



class District(models.Model):
    id_field = models.IntegerField()
    district = models.CharField(max_length=64)
    acres = models.FloatField()
    hectares = models.FloatField()
    geom = models.MultiPolygonField(srid=4326)


class NoaaTransmissionType(models.Model):
    acronym = models.CharField(max_length=5, unique=True)
    description = models.CharField(max_length=255)

    def __str__(self):
        return self.acronym


class NoaaTransmissionRate(models.Model):
    rate = models.IntegerField(unique=True)

    def __str__(self):
        return str(self.rate)


class NoaaDcp(BaseModel):
    dcp_address = models.CharField(max_length=256)
    first_channel = models.IntegerField(null=True, blank=True)
    first_channel_type = models.ForeignKey(NoaaTransmissionType, on_delete=models.CASCADE, related_name="first_channels", null=True, blank=True)
    second_channel = models.IntegerField(null=True, blank=True)
    second_channel_type = models.ForeignKey(NoaaTransmissionType, on_delete=models.CASCADE,
                                            related_name="second_channels", null=True, blank=True)
    first_transmission_time = models.TimeField()
    transmission_window = models.TimeField()
    transmission_period = models.TimeField()
    last_datetime = models.DateTimeField(null=True, blank=True)
    config_file = models.FileField(upload_to='', null=True, blank=True)
    config_data = models.TextField(null=True, blank=True)

    def save(self, *args, **kwargs):
        if self.config_file.name is not None:
            if self.config_file.name.endswith('.ssf'):
                self.config_data = self.config_file.open("r").read()
                self.config_file.delete()
        super().save(*args, **kwargs)         

    def __str__(self):
        return self.dcp_address


class NoaaDcpsStation(BaseModel):
    station = models.ForeignKey(Station, on_delete=models.CASCADE)
    noaa_dcp = models.ForeignKey(NoaaDcp, on_delete=models.CASCADE)
    decoder = models.ForeignKey(Decoder, on_delete=models.CASCADE)
    interval = models.ForeignKey(Interval, on_delete=models.CASCADE)
    format = models.ForeignKey(Format, on_delete=models.CASCADE)
    start_date = models.DateTimeField()
    end_date = models.DateTimeField(null=True, blank=True)

    def __str__(self):
        return "{} {} - {}".format(self.station, self.noaa_dcp, self.interval)

    class Meta:
        verbose_name = "NMS DCP Station"
        verbose_name_plural = "NMS DCP Stations"


class Flash(BaseModel):
    type = models.CharField(max_length=60, choices=[(flashType.name, flashType.value) for flashType in FlashTypeEnum])
    datetime = models.DateTimeField()
    latitude = models.FloatField()
    longitude = models.FloatField()
    peak_current = models.IntegerField()
    ic_height = models.IntegerField()
    num_sensors = models.IntegerField()
    ic_multiplicity = models.IntegerField()
    cg_multiplicity = models.IntegerField()
    start_datetime = models.DateTimeField()
    duration = models.IntegerField()
    ul_latitude = models.FloatField()
    ul_longitude = models.FloatField()
    lr_latitude = models.FloatField()
    lr_longitude = models.FloatField()

    def __str__(self):
        return "{} {} - {}".format(self.latitude, self.longitude, self.datetime)


class QcRangeThreshold(BaseModel):
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    variable = models.ForeignKey(Variable, on_delete=models.DO_NOTHING)
    interval = models.IntegerField(null=True, blank=True)
    range_min = models.FloatField(null=True, blank=True)
    range_max = models.FloatField(null=True, blank=True)
    month = models.IntegerField(default=1)

    def __str__(self):
        return f"station={self.station.code} variable={self.variable.symbol} interval={self.interval}"

    class Meta:
        ordering = ('station', 'variable', 'month', 'interval',)
        unique_together = ("station", "variable", "month", "interval",)


class QcStepThreshold(BaseModel):
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    variable = models.ForeignKey(Variable, on_delete=models.DO_NOTHING)
    interval = models.IntegerField(null=True, blank=True)
    step_min = models.FloatField(null=True, blank=True)
    step_max = models.FloatField(null=True, blank=True)

    class Meta:
        ordering = ('station', 'variable', 'interval')
        unique_together = ("station", "variable", "interval")


class QcPersistThreshold(BaseModel):
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    variable = models.ForeignKey(Variable, on_delete=models.DO_NOTHING)
    interval = models.IntegerField()
    window = models.IntegerField()
    minimum_variance = models.FloatField()

    class Meta:
        ordering = ('station', 'variable', 'interval')
        unique_together = ("station", "variable", "interval")


class FTPServer(BaseModel):
    name = models.CharField(max_length=64, unique=True)
    host = models.CharField(max_length=256)
    port = models.IntegerField()
    username = models.CharField(max_length=128)
    password = models.CharField(max_length=128)
    is_active_mode = models.BooleanField()

    def __str__(self):
        return f'{self.name} - {self.host}:{self.port}'

    class Meta:
        unique_together = ('host', 'port', 'username', 'password')


class StationFileIngestion(BaseModel):
    ftp_server = models.ForeignKey(FTPServer, on_delete=models.DO_NOTHING)
    remote_folder = models.CharField(max_length=1024)
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    file_pattern = models.CharField(max_length=256)
    decoder = models.ForeignKey(Decoder, on_delete=models.DO_NOTHING)
    cron_schedule = models.CharField(max_length=64, default='15/15 * * * *')
    utc_offset_minutes = models.IntegerField()
    delete_from_server = models.BooleanField()
    is_active = models.BooleanField(default=True)
    is_binary_transfer = models.BooleanField(default=False)
    is_historical_data = models.BooleanField(default=False)
    is_highfrequency_data = models.BooleanField(default=False)
    override_data_on_conflict = models.BooleanField(default=False)

    class Meta:
        unique_together = ('ftp_server', 'remote_folder', 'station')

    def __str__(self):
        return f'{self.ftp_server} - {self.station}'


class StationDataFileStatus(BaseModel):
    name = models.CharField(max_length=128)

    def __str__(self):
        return self.name

    class Meta:
        verbose_name = "station data file status"
        verbose_name_plural = "station data file statuses"


class StationDataFile(BaseModel):
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    decoder = models.ForeignKey(Decoder, on_delete=models.DO_NOTHING)
    status = models.ForeignKey(StationDataFileStatus, on_delete=models.DO_NOTHING)
    utc_offset_minutes = models.IntegerField()
    filepath = models.CharField(max_length=1024)
    file_hash = models.CharField(max_length=128, db_index=True)
    file_size = models.IntegerField()
    observation = models.TextField(max_length=1024, null=True, blank=True)
    is_historical_data = models.BooleanField(default=False)
    is_highfrequency_data = models.BooleanField(default=False)
    override_data_on_conflict = models.BooleanField(default=False)

    def __str__(self):
        return f'{self.filepath}'


class HourlySummaryTask(BaseModel):
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    datetime = models.DateTimeField()
    started_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)


class DailySummaryTask(BaseModel):
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    date = models.DateField()
    started_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)


class DcpMessages(BaseModel):
    # 8 hex digit DCP Address
    noaa_dcp = models.ForeignKey(NoaaDcp, on_delete=models.DO_NOTHING)

    # YYDDDHHMMSS – Time the message arrived at the Wallops receive station.
    # The day is represented as a three digit day of the year (julian day).
    datetime = models.DateTimeField()

    # 1 character failure code
    failure_code = models.CharField(max_length=1)

    # 2 decimal digit signal strength
    signal_strength = models.CharField(max_length=2)

    # 2 decimal digit frequency offset
    frequency_offset = models.CharField(max_length=2)

    # 1 character modulation index
    modulation_index = models.CharField(max_length=1)

    # 1 character data quality indicator
    data_quality = models.CharField(max_length=1)

    # 3 decimal digit GOES receive channel
    channel = models.CharField(max_length=3)

    # 1 character GOES spacecraft indicator (‘E’ or ‘W’)
    spacecraft_indicator = models.CharField(max_length=1)

    # 2 character data source code Data Source Code Table
    data_source = models.ForeignKey(DataSource, on_delete=models.DO_NOTHING)

    # 5 decimal digit message data length
    message_data_length = models.CharField(max_length=5)

    payload = models.TextField()

    def station(self):
        return NoaaDcpsStation.objects.get(noaa_dcp=self.noaa_dcp).station

    class Meta:
        unique_together = ('noaa_dcp', 'datetime')
        ordering = ('noaa_dcp', 'datetime')

    @classmethod
    def create(cls, header, payload):
        # 5020734E20131172412G44+0NN117EXE00278
        dcp_address = header[:8]
        print(f"create header={header}  dcp_address={dcp_address}")
        noaa_dcp = NoaaDcp.objects.get(dcp_address=dcp_address)
        datetime = pytz.utc.localize(dt.strptime(header[8:19], '%y%j%H%M%S'))
        failure_code = header[19:20]
        signal_strength = header[20:22]
        frequency_offset = header[22:24]
        modulation_index = header[24:25]
        data_quality = header[25:26]
        channel = header[26:29]
        spacecraft_indicator = header[29:30]
        data_source = header[30:32]
        data_source_obj, created = DataSource.objects.get_or_create(symbol=data_source,
                                                                    defaults={
                                                                        'name': data_source,
                                                                        'created_at': now(),
                                                                        'updated_at': now()
                                                                    })
        message_data_length = header[32:37]

        dcp_msg = cls(
            noaa_dcp=noaa_dcp,
            datetime=datetime,
            failure_code=failure_code,
            signal_strength=signal_strength,
            frequency_offset=frequency_offset,
            modulation_index=modulation_index,
            data_quality=data_quality,
            channel=channel,
            spacecraft_indicator=spacecraft_indicator,
            data_source=data_source_obj,
            message_data_length=message_data_length,
            payload=payload
        )

        return dcp_msg


class RatingCurve(BaseModel):
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    start_date = models.DateTimeField()

    def __str__(self):
        return f'{self.station.name} - {self.start_date}'


class RatingCurveTable(BaseModel):
    rating_curve = models.ForeignKey(RatingCurve, on_delete=models.DO_NOTHING)
    h = models.FloatField()
    q = models.FloatField()


class WxPermission(BaseModel):
    name = models.CharField(max_length=256, unique=True)
    url_name = models.CharField(max_length=256)
    permission = models.CharField(max_length=32, choices=(
        ('read', 'Read'), ('write', 'Write'), ('update', 'Update'), ('delete', 'Delete')))

    def __str__(self):
        return self.name


class WxGroupPermission(BaseModel):
    group = models.OneToOneField(Group, on_delete=models.DO_NOTHING)
    permissions = models.ManyToManyField(WxPermission)

    def __str__(self):
        return self.group.name


class StationImage(BaseModel):
    station = models.ForeignKey(Station, related_name='station_images', on_delete=models.CASCADE)
    name = models.CharField(max_length=256)
    path = models.FileField(upload_to='station_images/%Y/%m/%d/')
    description = models.CharField(max_length=256, null=True, blank=True)

    def __str__(self):
        return self.name


class HydroMLPrediction(BaseModel):
    name = models.CharField(max_length=256)
    hydroml_prediction_id = models.IntegerField()
    variable = models.ForeignKey(Variable, on_delete=models.DO_NOTHING)

    class Meta:
        unique_together = ('hydroml_prediction_id', 'variable')

    def __str__(self):
        return self.name


class HydroMLPredictionMapping(BaseModel):
    hydroml_prediction = models.ForeignKey(HydroMLPrediction, on_delete=models.DO_NOTHING)
    prediction_result = models.CharField(max_length=32)
    quality_flag = models.ForeignKey(QualityFlag, on_delete=models.DO_NOTHING)

    class Meta:
        unique_together = ('hydroml_prediction', 'quality_flag')

    def __str__(self):
        return f'{self.prediction_result} - {self.quality_flag}'


class Neighborhood(BaseModel):
    name = models.CharField(max_length=256, unique=True)

    def __str__(self):
        return self.name


class StationNeighborhood(BaseModel):
    neighborhood = models.ForeignKey(Neighborhood, related_name='neighborhood_stations', on_delete=models.DO_NOTHING)
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)

    class Meta:
        unique_together = ('neighborhood', 'station')

    def __str__(self):
        return f'{self.neighborhood.name} - {self.station}'


class HydroMLPredictionStation(BaseModel):
    prediction = models.ForeignKey(HydroMLPrediction, on_delete=models.DO_NOTHING)
    neighborhood = models.ForeignKey(Neighborhood, on_delete=models.DO_NOTHING)
    target_station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    data_period_in_minutes = models.IntegerField()
    interval_in_minutes = models.IntegerField()

    def __str__(self):
        return f'{self.prediction.name} - {self.neighborhood.name}'


class StationDataMinimumInterval(BaseModel):
    datetime = models.DateTimeField()
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    variable = models.ForeignKey(Variable, on_delete=models.DO_NOTHING)
    minimum_interval = models.TimeField(null=True, blank=True)
    record_count = models.IntegerField()
    ideal_record_count = models.IntegerField()
    record_count_percentage = models.FloatField()

    class Meta:
        unique_together = ('datetime', 'station', 'variable')

    def __str__(self):
        return f'{self.datetime}: {self.station} - {self.variable}'


class BackupTask(BaseModel):
    def cron_validator(cron_exp):
        if not croniter.is_valid(cron_exp):
            raise ValidationError('%(cron_exp)s is not a valid cron expression!',
                                  params={'cron_exp': cron_exp})

    name = models.CharField(max_length=1024)
    cron_schedule = models.CharField(max_length=64, default='0 0 * * *', validators=[cron_validator])
    file_name = models.CharField(max_length=1024)
    retention = models.IntegerField(verbose_name="Retention (in days)")
    ftp_server = models.ForeignKey(FTPServer, on_delete=models.DO_NOTHING, null=True, blank=True)
    remote_folder = models.CharField(max_length=1024)
    is_active = models.BooleanField()

    def __str__(self):
        return self.name  


class BackupLog(BaseModel):
    started_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)
    status = models.CharField(max_length=64)
    message = models.CharField(max_length=1024)
    backup_task = models.ForeignKey(BackupTask, on_delete=models.CASCADE)
    file_path = models.CharField(max_length=1024)
    file_size = models.FloatField(null=True, blank=True, verbose_name="File Size (MB)")


class ElementDecoder(BaseModel):
    element_name = models.CharField(max_length=64)
    variable = models.ForeignKey(Variable, on_delete=models.DO_NOTHING, null=True, blank=True)
    decoder = models.ForeignKey(Decoder, on_delete=models.DO_NOTHING, null=True, blank=True)


class HighFrequencyData(BaseModel):
    datetime = TimescaleDateTimeField(interval="1 day")
    measured = models.FloatField()
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    variable = models.ForeignKey(Variable, on_delete=models.DO_NOTHING)

    objects = models.Manager()
    timescale = TimescaleManager()

    class Meta:
        constraints =[models.UniqueConstraint(
                fields=['datetime', 'station', 'variable'],
                name="unique_datetime_station_id_variable_id"
             ),
        ]


class HFSummaryTask(BaseModel):
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    variable = models.ForeignKey(Variable, on_delete=models.DO_NOTHING)
    start_datetime = models.DateTimeField()
    end_datetime = models.DateTimeField()
    started_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        unique_together = ('station', 'variable', 'start_datetime', 'end_datetime')


class Manufacturer(BaseModel):
    name = models.CharField(max_length=64)

    def __str__(self):
        return self.name
 

class FundingSource(BaseModel):
    name = models.CharField(max_length=128)

    def __str__(self):
        return self.name    


class EquipmentType(BaseModel):
    name = models.CharField(max_length=64)
    description = models.CharField(max_length=256)
    report_template = RichTextField(blank=True, null=True)

    class Meta:
        verbose_name = "equipment type"
        verbose_name_plural = "equipment types"

    def __str__(self):
        return self.name  


class Equipment(BaseModel):
    class EquipmentClassification(models.TextChoices):
        FULLY_FUNCTIONAL = 'F', gettext_lazy('Fully Functional')
        PARTIALLY_FUNCTIONAL = 'P', gettext_lazy('Partially Functional')
        NOT_FUNCTIONAL = 'N', gettext_lazy('Not Functional')

    equipment_type = models.ForeignKey(EquipmentType, on_delete=models.DO_NOTHING)
    manufacturer = models.ForeignKey(Manufacturer, on_delete=models.DO_NOTHING)
    funding_source = models.ForeignKey(FundingSource, on_delete=models.DO_NOTHING)
    model = models.CharField(max_length=64)
    serial_number = models.CharField(max_length=64)
    acquisition_date = models.DateField()
    first_deploy_date = models.DateField(blank=True, null=True)
    last_deploy_date = models.DateField(blank=True, null=True)
    last_calibration_date = models.DateField(blank=True, null=True)
    next_calibration_date = models.DateField(blank=True, null=True)
    decommission_date = models.DateField(blank=True, null=True)
    classification = models.CharField(max_length=1, choices=EquipmentClassification.choices, null=True)
    history = HistoricalRecords()

    class Meta:
        unique_together = ("equipment_type", "serial_number")
        verbose_name = "equipment"
        verbose_name_plural = "equipment"

    def __str__(self):
        return ' '.join((self.equipment_type.name, self.model, self.serial_number))        


class VisitType(BaseModel):
    name = models.CharField(max_length=64, unique=True, blank=False, null=False)
    description = models.CharField(max_length=256, blank=True, null=True)


class Technician(BaseModel): # Singular
    name = models.CharField(max_length=64, unique=True, blank=False, null=False)


def no_future(value):
    today = date.today()
    if value > today:
        raise ValidationError('Visit date cannot be in the future.')


class MaintenanceReport(BaseModel):
    class Status(models.TextChoices):
        APPROVED = 'A', gettext_lazy('Approved')
        DRAFT = 'D', gettext_lazy('Draft')
        PUBLISHED = 'P', gettext_lazy('Published')
        DELETED = '-', gettext_lazy('Deleted')

    # New Maintenace Report
    station = models.ForeignKey(Station, on_delete=models.DO_NOTHING)
    # https://stackoverflow.com/questions/49882526/validation-for-datefield-so-it-doesnt-take-future-dates-in-django
    visit_type = models.ForeignKey(VisitType, on_delete=models.DO_NOTHING)
    responsible_technician = models.ForeignKey(Technician, related_name='responsible_technician', on_delete=models.DO_NOTHING)
    visit_date = models.DateField(help_text="Enter the date of the visit", validators=[no_future])
    initial_time = models.TimeField() # Sem timezone

    status = models.CharField(max_length=1, choices=Status.choices, default=Status.DRAFT)
    
    # First Snippet
    station_on_arrival_conditions = RichTextField(blank=True, null=True)

    # Penultimate Snippet
    contacts = RichTextField(blank=True, null=True)

    # Last Snippet
    other_technician_1 = models.ForeignKey(Technician, related_name='other_technician_1', on_delete=models.DO_NOTHING, blank=True, null=True)
    other_technician_2 = models.ForeignKey(Technician, related_name='other_technician_2', on_delete=models.DO_NOTHING, blank=True, null=True)
    other_technician_3 = models.ForeignKey(Technician, related_name='other_technician_3', on_delete=models.DO_NOTHING, blank=True, null=True)

    next_visit_date = models.DateField(blank=True, null=True)
    end_time = models.TimeField(blank=True, null=True) # Sem timezone

    current_visit_summary = RichTextField(blank=True, null=True)
    next_visit_summary = RichTextField(blank=True, null=True)

    data_logger_file = models.TextField(blank=True, null=True)
    data_logger_file_name = models.TextField(blank=True, null=True)

    class Meta:
        unique_together = ('station', 'visit_date')    


class StationProfileEquipmentType(BaseModel):
    station_profile = models.ForeignKey(StationProfile, on_delete=models.DO_NOTHING)
    equipment_type = models.ForeignKey(EquipmentType, on_delete=models.DO_NOTHING)
    equipment_type_order = models.IntegerField(validators=[MinValueValidator(1)])

    class Meta:
        unique_together = (('station_profile', 'equipment_type'), ('station_profile', 'equipment_type_order'))


class MaintenanceReportEquipment(BaseModel):
    class EquipmentClassification(models.TextChoices):
        FULLY_FUNCTIONAL = 'F', gettext_lazy('Fully Functional')
        PARTIALLY_FUNCTIONAL = 'P', gettext_lazy('Partially Functional')
        NOT_FUNCTIONAL = 'N', gettext_lazy('Not Functional')

    class EquipmentOrder(models.TextChoices):
        PRIMARY_EQUIPMENT = 'P', gettext_lazy('Primary Equipment')
        SECONDARY_EQUIPMENT = 'S', gettext_lazy('Secondary Equipment')
    
    maintenance_report = models.ForeignKey(MaintenanceReport, on_delete=models.CASCADE)
    equipment_type = models.ForeignKey(EquipmentType, on_delete=models.DO_NOTHING)
    equipment_order = models.CharField(max_length=1, choices=EquipmentOrder.choices, default=EquipmentClassification.FULLY_FUNCTIONAL)
    old_equipment = models.ForeignKey(Equipment, on_delete=models.DO_NOTHING, related_name='old_equipment', null=True)
    new_equipment = models.ForeignKey(Equipment, on_delete=models.DO_NOTHING, related_name='new_equipment', null=True)
    condition = RichTextField()
    classification = models.CharField(max_length=1, choices=EquipmentClassification.choices, default=EquipmentClassification.FULLY_FUNCTIONAL, null=True)

    class Meta:
        unique_together = (('maintenance_report', 'new_equipment'), ('maintenance_report', 'equipment_type', 'equipment_order'))


class GrowthStage(models.TextChoices):
    INITIAL = 'initial', 'Initial'
    DEVELOPMENT = 'development', 'Development'
    MID = 'mid', 'Mid-season'
    LATE = 'late', 'Late-season'

# class Culture(BaseModel):
#     name = models.CharField(max_length=64)
#     cycle = models.IntegerField(default=90)
#     class Meta:
#         unique_together = (('name', 'cycle'))

# class CultureCoeficients(BaseModel):
#     culture = models.ForeignKey(Culture, on_delete=models.CASCADE, related_name="coefficients")
#     stage = models.CharField(max_length=32, choices=GrowthStage.choices)
#     kc = models.FloatField()
#     class Meta:
#         unique_together = (('culture', 'stage'))


class Crop(BaseModel):
    name = models.CharField(max_length=64)
    cycle = models.IntegerField()
    max_ht = models.FloatField()
    l_ini = models.IntegerField()
    l_dev = models.IntegerField()
    l_mid = models.IntegerField()
    l_late = models.IntegerField()
    kc_ini = models.FloatField()
    kc_mid = models.FloatField()
    kc_end = models.FloatField()    
    class Meta:
        unique_together = (('name', 'cycle'))
