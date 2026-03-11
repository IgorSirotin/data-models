# data-models

Generates NuGet packages with abstract ASP.NET Core controllers and models from OpenAPI YAML files.

Each subdirectory in `openapi/` is treated as a separate package source:

```text
openapi/hotel-booking -> packages/HotelBooking -> DataModels.HotelBooking
openapi/appointment   -> packages/Appointment  -> DataModels.Appointment
```

Commands:

```powershell
mvn generate-sources
mvn package
```

Local default package version:

```text
0.1.0.0
```

GitHub Actions package version:

```text
0.1.0.${{ github.run_attempt }}
```

NuGet package output:

```text
artifacts/nuget/*.nupkg
```

GitHub Actions:

- `pull_request` and pushes to `main`/`master` run CI build.
- tags `v*` and manual `workflow_dispatch` publish generated packages to GitHub Packages.