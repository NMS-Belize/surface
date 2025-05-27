from django import forms
from wx.models import CountryISOCode, UTCOffsetMinutes
from django.conf import settings
from django.contrib.admin.widgets import FilteredSelectMultiple
from django.utils.safestring import mark_safe

from wx.models import Station, Watershed, AdministrativeRegion, FTPServer, WxGroupPermission, WxPermission

class FTPServerForm(forms.ModelForm):
    password = forms.CharField(widget=forms.TextInput(attrs={"type": "password"}))

    class Meta:
        model = FTPServer
        fields = '__all__'


class StationForm(forms.ModelForm):
    # Display `hours` but store `minutes`
    utc_offset_minutes = forms.ModelChoiceField(
        queryset=UTCOffsetMinutes.objects.all(),
        to_field_name="minutes",  # Store minutes in the database
    )

    # configured dropdown for watershed option
    watershed = forms.ChoiceField(required=False)

    # configure wigos section options
    wigos_part_1 = forms.IntegerField(initial='0', disabled=True, required=False, label='WIGOS ID Series')
    # wigos_part_3 = forms.IntegerField(min_value=0, max_value=65534, required=False, label='Issue Number')
    # wigos_part_4 = forms.CharField(max_length=16, required=False, label='Local Identifier')

    class Meta:
        model = Station
        fields = '__all__'
        labels = {
            'wigos': 'WIGOS ID',
            'code': 'Station ID',
            'wigos_part_1': 'WIGOS ID Series',
            'wigos_part_2': 'Issuer of Identifier',
            'wigos_part_3': 'Issue Number',
            'wigos_part_4': 'Local Identifier',
            'utc_offset_minutes': 'UTC Offset',
            'wmo': 'WMO Program',
            'relocation_date' : 'Date of Relocation',
            # 'is_active' : 'Station Operation Status (Active or Inactive)',
            # 'is_automatic' : 'Conventional or Automatic',
            'network' : 'Network (Local)',
            'profile' : 'Type of Station (Local Profile)',
            'region' : 'Local Administrative Region',
            'wmo_station_plataform' : 'Station/Platform model (WMO)',
            'data_type': 'Data Communication Method',
            'observer' : 'Local Observer Name',
            'organization' : 'Responsible Organization (Local)',
        }
        help_texts = {
            'international_exchange': 'Upon selection, the station will be available in the WIS2 configuration dashboard. Head there to modify the default settings and customize how the station is published to WIS2.',
            'region': 'If this option is not applicable, please select "Not Specified".'
        }
        # widgets = {
        #     'wigos_part_3': forms.NumberInput(attrs={
        #         'title': 'Enter the issue number (0 to 65534) for this WIGOS identifier part.',``
        #         # 'class': 'form-control'
        #     }),
        # }

    def __init__(self, *args, **kwargs):
        super(StationForm, self).__init__(*args, **kwargs)
        
        # Set initial value for utc_offset_minutes from the database based on settings.TIMEZONE_OFFSET
        utc_offset_minutes_instance = UTCOffsetMinutes.objects.filter(minutes=settings.TIMEZONE_OFFSET).first()

        if utc_offset_minutes_instance:
            self.fields['utc_offset_minutes'].initial = utc_offset_minutes_instance
        

        # Dynamically fetch watershed choices from the database
        watershed_options = [('','---------')] + [(x, x) for x in Watershed.objects.values_list('watershed', flat=True)]
        self.fields['watershed'].choices = watershed_options

    def clean(self):
        cleaned_data = super().clean()

        # Get the individual parts of the WIGOS ID
        wigos_part_1 = cleaned_data.get('wigos_part_1')
        wigos_part_2 = cleaned_data.get('wigos_part_2')
        wigos_part_3 = cleaned_data.get('wigos_part_3')
        wigos_part_4 = cleaned_data.get('wigos_part_4')

        # Combine the parts into a single string separated by '-'
        obj = CountryISOCode.objects.filter(name=wigos_part_2).first()

        if obj:
            iso_code = obj.notation

            wigos_combined = f"{wigos_part_1}-{iso_code}-{wigos_part_3}-{wigos_part_4}"

            # Set the combined value to the 'wigos' field
            cleaned_data['wigos'] = wigos_combined

        # get the timezone in minutes
        cleaned_data['utc_offset_minutes'] = UTCOffsetMinutes.objects.filter(hours=cleaned_data.get('utc_offset_minutes')).first().minutes

        return cleaned_data


class WxGroupPermissionForm(forms.ModelForm):
    permissions = forms.ModelMultipleChoiceField(
        queryset=WxPermission.objects.all(),
        required=True,
        widget=FilteredSelectMultiple(
            verbose_name='Permissions',
            is_stacked=False
        )
    )

    class Meta:
        model = WxGroupPermission
        fields = '__all__'