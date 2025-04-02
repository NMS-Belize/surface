from rest_framework import serializers

from wx import models


class CountrySerializer(serializers.ModelSerializer):
    class Meta:
        model = models.Country
        fields = '__all__'


class UnitSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.Unit
        fields = '__all__'


class VariableSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.Variable
        fields = '__all__'


class VariableSerializerSimplified(serializers.ModelSerializer):
    unit_name = serializers.CharField(source='unit.name', read_only=True)
    unit_symbol = serializers.CharField(source='unit.symbol', read_only=True)

    class Meta:
        model = models.Variable
        fields = ('symbol', 'name', 'unit_name', 'unit_symbol')


class DataSourceSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.DataSource
        fields = '__all__'


class StationVariableSerializer(serializers.ModelSerializer):
    variable_name = serializers.CharField(source='variable.name')
    symbol = serializers.CharField(source='variable.symbol')
    measurement_variable = serializers.CharField(source='variable.measurement_variable.name', read_only=True)
    unit_name = serializers.CharField(source='variable.unit.name', read_only=True)
    unit_symbol = serializers.CharField(source='variable.unit.symbol', read_only=True)
    color = serializers.CharField(source='variable.color', read_only=True)
    default_representation = serializers.CharField(source='variable.default_representation', read_only=True)

    class Meta:
        model = models.StationVariable
        fields = '__all__'


class StationProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.StationProfile
        fields = '__all__'


class StationTypeSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.StationType
        fields = '__all__'


class StationSerializerWrite(serializers.ModelSerializer):
    class Meta:
        model = models.Station
        fields = '__all__'


class StationCommunicationSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.StationCommunication
        fields = '__all__'


class StationSerializerRead(serializers.ModelSerializer):
    data_source = DataSourceSerializer(read_only=True)

    class Meta:
        model = models.Station
        fields = (
            'id',
            'name',
            'alias_name',
            'begin_date',
            'end_date',
            'longitude',
            'latitude',
            'elevation',
            'code',
            'wmo',
            'wigos',
            'organization',
            'observer',
            'watershed',
            'z',
            'datum',
            'zone',
            'ground_water_province',
            'river_code',
            'river_course',
            'catchment_area_station',
            'river_origin',
            'easting',
            'northing',
            'river_outlet',
            'river_length',
            'local_land_use',
            'soil_type',
            'site_description',
            'land_surface_elevation',
            'screen_length',
            'top_casing_land_surface',
            'depth_midpoint',
            'screen_size',
            'casing_type',
            'casing_diameter',
            'existing_gauges',
            'flow_direction_at_station',
            'flow_direction_above_station',
            'flow_direction_below_station',
            'bank_full_stage',
            'bridge_level',
            'access_point',
            'temporary_benchmark',
            'mean_sea_level',
            'data_type',
            'frequency_observation',
            'historic_events',
            'other_information',
            'profile',
            'country',
            'region',
            'data_source',
            'is_automatic',
            'is_active',
            'communication_type',
            'hydrology_station_type',
            'station_details',
            'updated_at',
            'created_at',
            'utc_offset_minutes',
            'alternative_names',
            'wmo_station_type',
            'wmo_region',
            'wmo_program',
            'wmo_station_plataform',
            'operation_status',
            'relocation_date',
            'network',
        )


class StationSerializerReadSimple(serializers.ModelSerializer):
    class Meta:
        model = models.Station
        fields = ('id', 'name')


class StationSimpleSerializer(serializers.ModelSerializer):
    profile = serializers.CharField(source='profile.name', read_only=True)
    communication_type = serializers.CharField(source='communication_type.name', read_only=True)
    position = serializers.SerializerMethodField()

    def get_position(self, obj):
        return {'latitude': obj.latitude, 'longitude': obj.longitude}

    class Meta:
        model = models.Station
        fields = (
            'id',
            'name',
            'profile',
            'region',
            'watershed',
            'is_automatic',
            'is_active',
            'position',
            'communication_type',
        )


class DocumentSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.Document
        fields = '__all__'


class AdministrativeRegionSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.AdministrativeRegion
        fields = '__all__'


class StationFileSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.StationFile
        fields = '__all__'


class WatershedSerializer(serializers.ModelSerializer):
    name = serializers.CharField(source='watershed', read_only=True, )

    class Meta:
        model = models.Watershed
        fields = ('id', 'name')


class DecoderSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.Decoder
        fields = ('id', 'name')


class ReducedStationSerializer(serializers.ModelSerializer):
    id = serializers.CharField(source='station__id', read_only=True)
    name = serializers.CharField(source='station__name', read_only=True)
    code = serializers.CharField(source='station__code', read_only=True)

    class Meta:
        model = models.Station
        fields = ('id', 'name', 'code')


class QualityFlagSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.QualityFlag
        fields = '__all__'


class StationImageSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.StationImage
        fields = '__all__'

class StationMetadataSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.Station
        fields = (
        'name', 
        'alias_name',
        'id',
        'wigos',
        'wmo',
        'begin_date',
        'end_date',
        'relocation_date',
        'is_active',
        'is_automatic',
        'network',
        'wmo_station_type',
        'profile',
        'communication_type',
        'latitude',
        'longitude',
        'elevation',
        'country',
        'region', 
        'watershed',
        'wmo_region',
        'utc_offset_minutes',
        'wmo_station_plataform',
        'data_type', 
        'observer', 
        'organization',
        )

class StationVariableSeriesSerializer(serializers.Serializer):
    station_id = serializers.IntegerField()
    variable_id = serializers.IntegerField()

class DataExportSerializer(serializers.Serializer):
    data_source = serializers.CharField(max_length=32)
    file_format = serializers.CharField(max_length=16)
    interval = serializers.IntegerField()
    initial_date = serializers.DateField(format='%Y-%m-%d')
    initial_time = serializers.TimeField(format='%H:%M')
    final_date = serializers.DateField(format='%Y-%m-%d')
    final_time = serializers.TimeField(format='%H:%M')
    series = StationVariableSeriesSerializer(many=True)

class IntervalSerializer(serializers.ModelSerializer):
    class Meta:
        model = models.Interval
        fields = '__all__'
    

class LocalWisCredentialsSerializer(serializers.ModelSerializer):
    local_password = serializers.CharField(write_only=True, required=True)

    class Meta:
        model = models.LocalWisCredentials
        fields = [
            'local_wis2_ip_address', 'local_wis2_port', 'local_wis2_username', 'local_password'
        ]
    
    def update(self, instance, validated_data):
        # Update non-password fields
        for attr, value in validated_data.items():
            setattr(instance, attr, value)

        # Update passwords securely
        if 'local_password' in validated_data:
            instance.set_passwords(
                validated_data.pop('local_password')
            )

        instance.save()
        return instance


class RegionalWisCredentialsSerializer(serializers.ModelSerializer):
    regional_password = serializers.CharField(write_only=True, required=True)

    class Meta:
        model = models.RegionalWisCredentials
        fields = [
            'regional_wis2_ip_address', 'regional_wis2_port', 'regional_wis2_username', 'regional_password'
        ]
    
    def update(self, instance, validated_data):
        # Update non-password fields
        for attr, value in validated_data.items():
            setattr(instance, attr, value)

        # Update passwords securely
        if 'regional_password' in validated_data:
            instance.set_passwords(
                validated_data.pop('regional_password')
            )

        instance.save()
        return instance


class Wis2BoxPublishSerializer(serializers.ModelSerializer):

    class Meta:
        model = models.Wis2BoxPublish
        fields = '__all__'
    
    def update(self, instance, validated_data):
        # Update fields
        for attr, value in validated_data.items():
            setattr(instance, attr, value)

        instance.save()
        return instance
    

class Wis2BoxPublishSerializerReadPublishing(serializers.ModelSerializer):
    station_name = serializers.CharField(source='station.name')

    class Meta:
        model = models.Wis2BoxPublish
        fields = ['id', 'station_name']
    

class Wis2PublishOffsetSerializerRead(serializers.ModelSerializer):
    class Meta:
        model = models.Wis2PublishOffset
        fields = ('id', 'code', 'description')