#!/usr/bin/env python

import json
import pandas as pd
import sys

def main(input_file, output_file='exercises.csv'):
    # Load the JSON data from the input file
    with open(input_file, 'r') as f:
        data = json.load(f)

    # Initialize a list to hold the rows
    rows = []

    # Iterate over each category
    for category in data:
        category_key = category.get('exerciseCategoryKey', '')
        exercises = category.get('exercisesInCategory', [])
        
        # Iterate over each exercise in the category
        for exercise in exercises:
            exercise_key = exercise.get('exerciseKey', '')
            primary_muscles = ', '.join(exercise.get('primaryMuscles', []))
            secondary_muscles = ', '.join(exercise.get('secondaryMuscles', []))
            equipment_keys = ', '.join(exercise.get('equipmentKeys', []))
            
            # Append the row as a dictionary
            rows.append({
                'exerciseCategoryKey': category_key,
                'exerciseKey': exercise_key,
                'primaryMuscles': primary_muscles,
                'secondaryMuscles': secondary_muscles,
                'equipmentKeys': equipment_keys
            })

    # Create a DataFrame from the rows
    df = pd.DataFrame(rows)

    # Write the DataFrame to a CSV file
    df.to_csv(output_file, index=False)
    print(f"Spreadsheet written to {output_file}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python script.py <input_json_file> [output_csv_file]")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else 'exercises.csv'
    main(input_file, output_file)