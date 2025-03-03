from django.db.models.signals import post_save
from django.dispatch import receiver
from wx.models import Station, Wis2BoxPublish

@receiver(post_save, sender=Station)
def update_wis2boxPublish_on_international_exchange_change(sender, instance, **kwargs):
    """
    Ensure Wis2BoxPublish instances are created or deleted when the
    international_exchange field of a Station changes.
    """
    if instance.international_exchange:
        # Create a Wis2Box entry if it does not exist
        Wis2BoxPublish.objects.get_or_create(station=instance)
    else:
        # Delete the Wis2Box entry if the station no longer has international exchange
        Wis2BoxPublish.objects.filter(station=instance).delete()
