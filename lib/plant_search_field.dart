import 'package:flutter/material.dart';
import 'plant_type_service.dart';

class PlantSearchField extends StatelessWidget {
  final List<PlantType> plantTypes;
  final String? initialValue;
  final void Function(PlantType) onSelected;
  final InputDecoration? decoration;

  const PlantSearchField({
    Key? key,
    required this.plantTypes,
    required this.onSelected,
    this.initialValue,
    this.decoration,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<PlantType>(
      initialValue: initialValue != null && initialValue!.isNotEmpty
          ? TextEditingValue(text: initialValue!)
          : null,
      displayStringForOption: (p) => p.nameMarathi,
      optionsBuilder: (value) {
        if (value.text.isEmpty) return plantTypes;
        return plantTypes.where((p) => p.matches(value.text));
      },
      onSelected: onSelected,
      fieldViewBuilder: (context, controller, focusNode, onSubmit) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: decoration ??
              InputDecoration(
                labelText: 'रोपाचे नाव',
                border: const OutlineInputBorder(),
                hintText: 'मराठी / English मध्ये शोधा',
                suffixIcon: const Icon(Icons.arrow_drop_down),
              ),
          onEditingComplete: onSubmit,
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: options.length,
                itemBuilder: (_, i) {
                  final p = options.elementAt(i);
                  return InkWell(
                    onTap: () => onSelected(p),
                    child: ListTile(
                      dense: true,
                      title: Text(p.nameMarathi),
                      subtitle: p.nameEnglish.isNotEmpty
                          ? Text(
                              p.nameEnglish,
                              style: const TextStyle(fontSize: 11),
                            )
                          : null,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
