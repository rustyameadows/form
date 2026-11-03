#!/usr/bin/env python3
"""Project-authored mixed-stock publication data; never an app product preset.

This module is import-only. The explicit create function uses the existing
public publication command; the sheet plan itself is completely offline.
"""
from __future__ import annotations
import copy
import uuid

from publication_physical_examples import stock

NAMESPACE = uuid.UUID('7dc02af1-475d-40b9-b17d-9639452cc37d')
TRIM_MM = (215.9, 279.4)
PARENT_MM = (431.8, 279.4)
COLORED_PARENT_INDICES = frozenset((0, 4, 8, 12))


def identifier(value):
    return str(uuid.uuid5(NAMESPACE, value)).upper()


def uncoated_stock(name, thickness_mm, color, gsm):
    value = stock(name, thickness_mm, color, 'cotton', gsm=gsm)
    value['profile'].update(roughness=.96, textureScaleMM=.75, textureDepthMM=.009)
    value['notes'] = 'Uncoated visual stock specification. Physical caliper, ink and bindery proof remain unverified.'
    return value


def parent_sheet_plan(document):
    """Thirteen nested, duplex 11×17-inch parents for 52 letter-size pages.

    Front/back arrays are physical left/right print slots. PublicationPage.id
    owns identity; objectID identifies the ordinary canonical artwork page.
    Stock has exactly one editable declaration, on each folded parent sheet.
    """
    pages = document['pages']
    if len(pages) != 52:
        raise ValueError('This authored issue needs exactly 48 interior pages and four cover faces.')
    if (document.get('layout') or {}).get('firstPageSide', 'recto') != 'recto':
        raise ValueError('The authored quarterly begins with its recto front cover.')
    colored = {
        0: uncoated_stock('Outer sheet / uncoated ochre / 200 gsm', .22, '#D9BA70', 200),
        4: uncoated_stock('Colored sheet / pale sage / 110 gsm', .12, '#C9D6C3', 110),
        8: uncoated_stock('Colored sheet / powder blue / 110 gsm', .12, '#CEDDE5', 110),
        12: uncoated_stock('Center sheet / warm yellow / 110 gsm', .12, '#E6D394', 110),
    }
    white = uncoated_stock('White sheet / uncoated / 100 gsm', .10, '#F5F2EA', 100)
    parents = []
    evidence = []
    for index in range(13):
        numbers = (52 - 2*index, 1 + 2*index, 2 + 2*index, 51 - 2*index)
        entries = [pages[number-1] for number in numbers]
        value = dict(
            id=identifier(document['id'] + '/parent/' + str(index)),
            frontPageIDs=[entries[0]['id'], entries[1]['id']],
            backPageIDs=[entries[2]['id'], entries[3]['id']],
            stock=copy.deepcopy(colored.get(index, white)),
            sizeMM=dict(zip(('x', 'y'), PARENT_MM)),
            printIntent='blackOnly' if index in COLORED_PARENT_INDICES else 'color',
        )
        parents.append(value)
        evidence.append(dict(
            index=index, parent_id=value['id'], front=list(numbers[:2]), back=list(numbers[2:]),
            object_ids=[page['objectID'] for page in entries],
            print_intent=value['printIntent'], stock=copy.deepcopy(value['stock']),
            page_background_opacity=0,
        ))
    flattened = [number for row in evidence for number in row['front'] + row['back']]
    if sorted(flattened) != list(range(1, 53)):
        raise AssertionError('Each canonical page must occupy exactly one parent-face slot.')
    black_pages = sorted(number for row in evidence if row['print_intent']=='blackOnly'
                         for number in row['front'] + row['back'])
    return dict(
        parent_sheets=parents, evidence=evidence, black_only_pages=black_pages,
        color_pages=sorted(set(range(1, 53)) - set(black_pages)),
        trim_mm=list(TRIM_MM), parent_mm=list(PARENT_MM), source_bleed_mm=0,
        white_stock=white,
    )


def assembly_definition(document):
    plan = parent_sheet_plan(document)
    value = dict(
        version=1, publicationID=document['id'], stock=copy.deepcopy(plan['white_stock']),
        openingDegrees=0, activeSpread=0, bendMM=0,
        parentSheets=plan['parent_sheets'],
        binding=dict(style='saddleStitch', count=2, positionsMM=[50, 229.4], endMarginMM=50,
                     edgeInsetMM=8, crownLengthMM=12, wireDiameterMM=.45,
                     clinchLengthMM=2, flexWidthMM=10),
    )
    return value, plan


def create_magazine_physical(call, publication_id, name='Quarterly / linked physical source'):
    document = call('form_publication', command='get', publication_id=publication_id)
    definition, plan = assembly_definition(document)
    result = call('form_publication', command='sheet_assembly_create', publication_id=publication_id,
                  name=name, position=[0, 0, 0], definition=definition)
    return dict(object_id=result['object_id'], definition=definition, plan=plan,
                printing_note='Colored parent sheets require explicit process-K artwork; RGB black is not a K-only declaration.',
                proof_note='Digital source, stock, binding and rendering evidence; no physical press/bindery calibration.')
