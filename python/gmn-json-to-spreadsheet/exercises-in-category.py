#!/usr/bin/env python3

import json
import pandas as pd
import sys
from pathlib import Path


def main(input_file, output_file='exercises.csv', muscles_file='unique_muscles.txt', equipment_file='unique_equipment.txt'):
    # Load the JSON data
    with open(input_file, 'r', encoding='utf-8') as f:
        data = json.load(f)

    # Main exercises data
    rows = []

    for category in data:
        category_key = category.get('exerciseCategoryKey', '')
        exercises = category.get('exercisesInCategory', [])
        
        for exercise in exercises:
            exercise_key = exercise.get('exerciseKey', '')
            primary_muscles = ', '.join(exercise.get('primaryMuscles', []))
            secondary_muscles = ', '.join(exercise.get('secondaryMuscles', []))
            equipment_keys = ', '.join(exercise.get('equipmentKeys', []))

            rows.append({
                'exerciseCategoryKey': category_key,
                'exerciseKey': exercise_key,
                'primaryMuscles': primary_muscles,
                'secondaryMuscles': secondary_muscles,
                'equipmentKeys': equipment_keys
            })

    # Create and save main spreadsheet
    df = pd.DataFrame(rows)
    df.to_csv(output_file, index=False, encoding='utf-8')
    print(f"Main exercise spreadsheet written to: {output_file}")

    all_muscles = set()
    all_equipment = set()

    for row in rows:
        # Split comma-separated strings back into lists and strip whitespace
        for m in row['primaryMuscles'].split(','):
            if m.strip():
                all_muscles.add(m.strip())
                
        for m in row['secondaryMuscles'].split(','):
            if m.strip():
                all_muscles.add(m.strip())
                
        for e in row['equipmentKeys'].split(','):
            if e.strip():
                all_equipment.add(e.strip())

    sorted_muscles = sorted(all_muscles)
    sorted_equipment = sorted(all_equipment)

    # Save unique muscle groups
    with open(muscles_file, 'w', encoding='utf-8') as f:
        f.write("Unique muscles (primary + secondary):\n")
        f.write("-" * 40 + "\n")
        for muscle in sorted_muscles:
            f.write(f"{muscle}\n")
    print(f"Unique muscles list written to: {muscles_file} ({len(sorted_muscles)} items)")

    # Save unique equipment
    with open(equipment_file, 'w', encoding='utf-8') as f:
        f.write("Unique equipment keys:\n")
        f.write("-" * 40 + "\n")
        for eq in sorted_equipment:
            f.write(f"{eq}\n")
    print(f"Unique equipment list written to: {equipment_file} ({len(sorted_equipment)} items)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print(f"  python {Path(__file__).name} <input_json_file> [output_csv] [muscles_txt] [equipment_txt]")
        print("Example:")
        print(f"  python {Path(__file__).name} exerciseToEquipments.json exercises.csv muscles.txt equipment.txt")
        sys.exit(1)

    input_file = sys.argv[1]
    
    output_file = sys.argv[2] if len(sys.argv) > 2 else 'exercises.csv'
    muscles_file = sys.argv[3] if len(sys.argv) > 3 else 'unique_muscles.txt'
    equipment_file = sys.argv[4] if len(sys.argv) > 4 else 'unique_equipment.txt'

    main(input_file, output_file, muscles_file, equipment_file)